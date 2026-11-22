import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:aveditor/services/api_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlanTier { free, plus, pro, studio }

/// One purchasable plan as shown on the paywall.
class ProPlan {
  const ProPlan({
    required this.id,
    required this.title,
    required this.price,
    required this.isAnnual,
    required this.tier,
    this.product,
    this.aiEnabled = false,
  });

  final String id;
  final String title;
  final String price;
  final bool isAnnual;
  final PlanTier tier;
  final bool aiEnabled;

  /// Store product backing this plan (null for debug placeholders).
  final ProductDetails? product;

  bool get isDebugPlaceholder => product == null && id.startsWith('debug_');
}

enum ProPurchaseResult { purchased, cancelled, failed, unavailable }

/// How selecting [ProPlan] relates to the user's current entitlement.
///
/// Store rules (same subscription group):
/// - Higher tier → immediate upgrade (prorated)
/// - Lower tier → deferred until current period ends
/// - Monthly → yearly (same tier) → upgrade
/// - Yearly → monthly (same tier) → blocked in-app (not offered)
enum PlanChangeKind {
  subscribe,
  current,
  upgrade,
  downgrade,
  periodDowngradeBlocked,
}

/// EasyClip subscription state (Plus / Pro / Studio) via native IAP.
///
/// Store Product IDs come from the dashboard plan config
/// (`storeProductIdMonthly` / `storeProductIdAnnual`).
///
/// Server (`/api/subscriptions/*`) is the entitlement source of truth after
/// purchase/restore, keyed by Firebase uid (app login required to verify).
/// Empty store catalog → paywall shows an error (no fake prices).
class ProService extends ChangeNotifier {
  ProService._();

  static final ProService instance = ProService._();

  /// Product IDs to query: enabled paid plans' dashboard Product IDs only.
  Set<String> productIdsFromDashboard() {
    final remote = CreditService.instance.plans;
    final ids = <String>{};
    _iapLog('dashboard plans count=${remote.length}');
    for (final plan in remote) {
      _iapLog(
        '  plan id=${plan.id} enabled=${plan.enabled} '
        'monthly=${plan.storeProductIdMonthly} '
        'annual=${plan.storeProductIdAnnual}',
      );
      if (!plan.enabled) continue;
      final tier = _parseTier(plan.id);
      if (tier == null || tier == PlanTier.free) continue;
      final monthly = plan.storeProductIdMonthly.trim();
      final annual = plan.storeProductIdAnnual.trim();
      if (monthly.isNotEmpty) ids.add(monthly);
      if (annual.isNotEmpty) ids.add(annual);
    }
    return ids;
  }

  static const _debugProKey = 'debug_pro_enabled';
  static const _debugTierKey = 'debug_plan_tier';
  static const _debugAnnualKey = 'debug_plan_annual';
  static const _cachedTierKey = 'store_plan_tier';
  static const _cachedProductKey = 'store_plan_product_id';

  final InAppPurchase _iap = InAppPurchase.instance;

  bool _initialized = false;
  bool _storeConfigured = false;
  PlanTier _storeTier = PlanTier.free;
  PlanTier _debugTier = PlanTier.free;
  /// Billing period for the debug entitlement (`null` when debug is off).
  bool? _debugAnnual;
  /// Store product id for the active subscription (monthly vs annual).
  String? _activeProductId;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  Completer<PurchaseDetails?>? _purchaseCompleter;
  String? _pendingProductId;

  /// True while launch/restore is collecting StoreKit purchases.
  bool _iapSyncActive = false;
  PlanTier _iapSyncBest = PlanTier.free;
  String? _iapSyncBestProductId;

  /// True when editing unlock is active (Plus / Pro / Studio / debug).
  bool get isPro => tier != PlanTier.free;

  /// Debug preset is active (overrides store entitlement for UI testing).
  bool get debugEntitlementActive =>
      kDebugMode && _debugTier != PlanTier.free;

  PlanTier get tier {
    // Debug preset wins so paywall UI can be forced through the 4 test cases.
    if (kDebugMode && _debugTier != PlanTier.free) return _debugTier;
    if (_storeTier != PlanTier.free) return _storeTier;
    return PlanTier.free;
  }

  /// Active IAP product id when known (e.g. `….plus.monthly`).
  String? get activeProductId {
    if (tier == PlanTier.free) return null;
    if (kDebugMode && _debugTier != PlanTier.free) {
      return _debugProductId(_debugTier, annual: _debugAnnual ?? false);
    }
    return _activeProductId;
  }

  /// `true` annual, `false` monthly, `null` if free or period unknown.
  bool? get activeIsAnnual {
    if (tier == PlanTier.free) return null;
    if (kDebugMode && _debugTier != PlanTier.free) {
      return _debugAnnual ?? false;
    }
    final id = _activeProductId;
    if (id != null && id.isNotEmpty) return _isAnnualProduct(id);
    return null;
  }

  /// Current debug UI preset, or `null` when off / release.
  ({PlanTier tier, bool annual})? get debugPreset {
    if (!kDebugMode || _debugTier == PlanTier.free) return null;
    return (tier: _debugTier, annual: _debugAnnual ?? false);
  }

  /// Whether [plan] is the subscription the user already owns.
  bool isCurrentPlan(ProPlan plan) {
    return changeKindFor(plan) == PlanChangeKind.current;
  }

  /// Classifies [plan] vs the active entitlement (upgrade / downgrade / …).
  PlanChangeKind changeKindFor(ProPlan plan) {
    if (plan.tier == PlanTier.free) return PlanChangeKind.current;
    if (tier == PlanTier.free) return PlanChangeKind.subscribe;

    final id = activeProductId;
    if (id != null && id.isNotEmpty && plan.id == id) {
      return PlanChangeKind.current;
    }

    final rankDelta = _tierRank(plan.tier) - _tierRank(tier);
    if (rankDelta > 0) return PlanChangeKind.upgrade;
    if (rankDelta < 0) return PlanChangeKind.downgrade;

    // Same tier — only the billing period can differ.
    final annual = activeIsAnnual;
    if (annual == null) {
      // Unknown period: don't allow a duplicate purchase of this tier.
      return PlanChangeKind.current;
    }
    if (!annual && plan.isAnnual) return PlanChangeKind.upgrade;
    if (annual && !plan.isAnnual) {
      return PlanChangeKind.periodDowngradeBlocked;
    }
    return PlanChangeKind.current;
  }

  /// Whether the paywall may start a store purchase for [plan].
  bool canPurchase(ProPlan plan) {
    final kind = changeKindFor(plan);
    return kind == PlanChangeKind.subscribe ||
        kind == PlanChangeKind.upgrade ||
        kind == PlanChangeKind.downgrade;
  }

  bool get isPurchaseInFlight =>
      _purchaseCompleter != null && !_purchaseCompleter!.isCompleted;

  bool get aiEnabled =>
      tier == PlanTier.pro || tier == PlanTier.studio;

  bool get storeAvailable => _storeConfigured;

  bool get debugProEnabled => _debugTier != PlanTier.free;

  String _debugProductId(PlanTier tier, {required bool annual}) {
    final remote = CreditService.instance.planById(switch (tier) {
      PlanTier.plus => 'plus',
      PlanTier.pro => 'pro',
      PlanTier.studio => 'studio',
      PlanTier.free => 'free',
    });
    if (remote != null) {
      final id = (annual
              ? remote.storeProductIdAnnual
              : remote.storeProductIdMonthly)
          .trim();
      if (id.isNotEmpty) return id;
    }
    final period = annual ? 'annual' : 'monthly';
    return 'com.smartcompany.aveditor.${tier.name}.$period';
  }

  /// Last store catalog error (null after a successful product query).
  String? lastCatalogError;

  void _iapLog(String message) {
    debugPrint('[ProService/IAP] $message');
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    if (kDebugMode) {
      final legacyOn = prefs.getBool(_debugProKey) ?? false;
      final stored = prefs.getString(_debugTierKey);
      _debugTier = _parseTier(stored) ??
          (legacyOn ? PlanTier.pro : PlanTier.free);
      if (_debugTier == PlanTier.free) {
        _debugAnnual = null;
      } else {
        _debugAnnual = prefs.getBool(_debugAnnualKey) ?? false;
      }
    }
    final cached = _parseTier(prefs.getString(_cachedTierKey));
    if (cached != null) _storeTier = cached;
    final cachedProduct = prefs.getString(_cachedProductKey)?.trim();
    if (cachedProduct != null && cachedProduct.isNotEmpty) {
      _activeProductId = cachedProduct;
    }

    String bundleId = 'unknown';
    String appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      bundleId = info.packageName;
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (e) {
      _iapLog('PackageInfo failed: $e');
    }

    final platform = kIsWeb
        ? 'web'
        : Platform.isIOS
            ? 'ios'
            : Platform.isAndroid
                ? 'android'
                : 'other';
    _iapLog(
      'init platform=$platform bundleId=$bundleId version=$appVersion '
      'debug=$kDebugMode cachedTier=${_storeTier.name}',
    );
    _iapLog(
      'query set comes from dashboard storeProductIdMonthly/Annual '
      'on enabled paid plans',
    );

    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      try {
        final available = await _iap.isAvailable();
        _iapLog('InAppPurchase.isAvailable=$available');
        if (available) {
          _storeConfigured = true;
          _purchaseSub = _iap.purchaseStream.listen(
            _onPurchaseUpdates,
            onError: (Object e) {
              _iapLog('purchaseStream error: $e');
            },
          );
          _iapLog('purchaseStream listener attached');
        } else {
          _iapLog(
            'STORE UNAVAILABLE — billing not usable on this build/device. '
            'Check: real device, Paid Apps agreement, not a China-restricted '
            'account restriction, StoreKit enabled.',
          );
        }
      } catch (e, st) {
        _iapLog('IAP init FAILED: $e');
        _iapLog('$st');
      }
    } else {
      _iapLog('skipping store init on unsupported platform');
    }

    // Entitlement at launch: StoreKit first, then /me (never wipe IAP with free).
    unawaited(_syncSubscriptionAtLaunch());
    notifyListeners();
  }

  int _tierRank(PlanTier tier) => switch (tier) {
        PlanTier.studio => 3,
        PlanTier.pro => 2,
        PlanTier.plus => 1,
        PlanTier.free => 0,
      };

  Future<void> _applyTier(
    PlanTier tier, {
    required bool allowDowngrade,
    String? productId,
  }) async {
    if (!allowDowngrade && _tierRank(tier) < _tierRank(_storeTier)) {
      _iapLog(
        'ignore downgrade ${_storeTier.name} → ${tier.name}',
      );
      return;
    }
    await _setStoreTier(tier, productId: productId);
  }

  /// App start: ask StoreKit what is owned, then reconcile with server /me.
  Future<void> _syncSubscriptionAtLaunch() async {
    if (!_storeConfigured) {
      await refreshEntitlementFromServer();
      return;
    }

    await ApiService.shared.ensureAuthToken();
    final loggedInAtStart = ApiService.shared.token?.isNotEmpty == true;
    // Account-based: without login, never surface a StoreKit-only paid plan.
    if (!loggedInAtStart) {
      await _setStoreTier(PlanTier.free);
      _iapLog('launch skip IAP sync — signed out → Free');
      return;
    }

    _iapLog('launch IAP sync start');
    _iapSyncActive = true;
    _iapSyncBest = PlanTier.free;
    _iapSyncBestProductId = null;
    try {
      await _iap.restorePurchases();
      // StoreKit delivers restored items asynchronously on purchaseStream.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_tierRank(_iapSyncBest) > _tierRank(_storeTier) ||
          (_iapSyncBest == _storeTier &&
              _iapSyncBestProductId != null &&
              _iapSyncBestProductId != _activeProductId)) {
        await _setStoreTier(
          _iapSyncBest,
          productId: _iapSyncBestProductId,
        );
      }
      _iapLog(
        'launch IAP sync done best=${_iapSyncBest.name} '
        'product=${_iapSyncBestProductId ?? '-'} '
        'local=${_storeTier.name}',
      );
    } catch (e) {
      _iapLog('launch IAP sync failed: $e');
    } finally {
      _iapSyncActive = false;
    }

    final iapTier = _storeTier;
    final iapProduct = _activeProductId;
    await refreshEntitlementFromServer();
    // Only reconcile StoreKit → local when an account is signed in.
    final loggedIn = ApiService.shared.token?.isNotEmpty == true;
    if (loggedIn && _tierRank(_storeTier) < _tierRank(iapTier)) {
      _iapLog(
        'keeping IAP tier ${iapTier.name} over server ${_storeTier.name}',
      );
      await _setStoreTier(iapTier, productId: iapProduct);
    }
  }

  Future<void> disposeListeners() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
  }

  static PlanTier? _parseTier(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw) {
      'plus' => PlanTier.plus,
      'pro' => PlanTier.pro,
      'studio' => PlanTier.studio,
      'free' => PlanTier.free,
      _ => null,
    };
  }

  static PlanTier tierFromProductId(String id) {
    final lower = id.toLowerCase();
    // Prefer dotted ASC ids: …aveditor.plus.monthly
    final parts = lower.split('.');
    for (final p in parts.reversed) {
      if (p == 'studio') return PlanTier.studio;
      if (p == 'plus') return PlanTier.plus;
      if (p == 'pro') return PlanTier.pro;
    }
    if (lower.contains('studio')) return PlanTier.studio;
    if (lower.contains('plus')) return PlanTier.plus;
    if (lower.contains('pro')) return PlanTier.pro;
    return PlanTier.free;
  }

  static bool _isAnnualProduct(String id) {
    final lower = id.toLowerCase();
    return lower.endsWith('.annual') || lower.contains('annual');
  }

  static int _rank(ProPlan p) {
    final t = switch (p.tier) {
      PlanTier.studio => 3,
      PlanTier.pro => 2,
      PlanTier.plus => 1,
      PlanTier.free => 0,
    };
    return t * 2 + (p.isAnnual ? 1 : 0);
  }

  Future<void> _setStoreTier(PlanTier next, {String? productId}) async {
    final resolvedProduct = next == PlanTier.free
        ? null
        : (productId?.trim().isNotEmpty == true
            ? productId!.trim()
            : _activeProductId);
    final tierChanged = _storeTier != next;
    final productChanged = resolvedProduct != _activeProductId;
    if (!tierChanged && !productChanged) return;
    _storeTier = next;
    _activeProductId = next == PlanTier.free ? null : resolvedProduct;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedTierKey, next.name);
    if (_activeProductId == null || _activeProductId!.isEmpty) {
      await prefs.remove(_cachedProductKey);
    } else {
      await prefs.setString(_cachedProductKey, _activeProductId!);
    }
    notifyListeners();
  }

  /// Account-based entitlement: signed-out users are always Free locally.
  Future<void> clearAccountEntitlement() async {
    await ensureInitialized();
    await _setStoreTier(PlanTier.free);
  }

  Future<void> refreshEntitlementFromServer() async {
    try {
      await CreditService.instance.ensureInitialized();
      final deviceKey = await CreditService.instance.deviceKey();
      final api = ApiService.shared;
      await api.ensureAuthToken();
      final token = api.token;
      final loggedIn = token != null && token.isNotEmpty;
      // Purchases are account-scoped; without login there is no paid plan.
      if (!loggedIn) {
        await _setStoreTier(PlanTier.free);
        return;
      }
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $token',
      };
      // Prefer account entitlement when logged in; deviceKey still merges
      // anonymous install credits/subs into the uid on the server.
      final uri = Uri.parse(
        '${CreditService.baseUrl}/api/subscriptions/me',
      ).replace(queryParameters: {'deviceKey': deviceKey});
      final res = await http.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        if (map is Map) {
          final tier = _parseTier(map['planTier'] as String?) ?? PlanTier.free;
          final productId = (map['productId'] as String?)?.trim();
          await _applyTier(
            tier,
            allowDowngrade: true,
            productId: productId,
          );
        }
      }
    } catch (e) {
      debugPrint('[ProService] entitlement refresh failed: $e');
    }
  }

  void _logIapError(IAPError? error) {
    if (error == null) {
      _iapLog('error=null');
      return;
    }
    _iapLog(
      'error.code=${error.code} source=${error.source} '
      'message=${error.message}',
    );
    _iapLog(
      'error.details type=${error.details?.runtimeType} value=${error.details}',
    );
    _iapLog('error.toString=$error');
    switch (error.code) {
      case 'storekit_no_response':
        _iapLog(
          'HINT storekit_no_response → StoreKit returned no product payload. '
          'Check ASC Paid Apps agreement; Product IDs character-exact; '
          'Subscription Group + pricing localized; bundleId=com.smartcompany.aveditor; '
          'real device; products created recently may need wait; '
          'Xcode Scheme → StoreKit Configuration = None.',
        );
      case 'storekit_duplicate_product_object':
        _iapLog('HINT duplicate product object in query set.');
      default:
        _iapLog('HINT unknown IAP error code=${error.code}');
    }
  }

  void _setCatalogError(String message) {
    lastCatalogError = message;
    _iapLog('catalogError=$message');
    notifyListeners();
  }

  /// Real store plans only. Empty list + [lastCatalogError] on failure.
  Future<List<ProPlan>> loadPlans() async {
    await ensureInitialized();
    await CreditService.instance.ensureInitialized();
    await CreditService.instance.ensurePlansLoaded();
    lastCatalogError = null;

    final productIds = productIdsFromDashboard();
    final ids = productIds.toList()..sort();
    _iapLog('──── loadPlans ────');
    _iapLog('storeConfigured=$_storeConfigured');
    _iapLog(
      'platform=${Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : 'other'}',
    );
    _iapLog('query count=${ids.length} (dashboard-enabled only)');
    for (var i = 0; i < ids.length; i++) {
      _iapLog('  [$i] ${ids[i]}');
    }

    if (ids.isEmpty) {
      _setCatalogError(
        'no_store_product_ids: enable a paid plan in dashboard 구독 플랜 '
        'and set Store Product ID (monthly/annual)',
      );
      return const [];
    }

    if (!_storeConfigured) {
      _setCatalogError(
        'store_unavailable: InAppPurchase.isAvailable=false '
        '(see init log)',
      );
      return const [];
    }

    try {
      final sw = Stopwatch()..start();
      _iapLog('calling queryProductDetails for ${ids.length} ids…');
      final response = await _iap.queryProductDetails(productIds);
      sw.stop();
      final found = response.productDetails;
      _iapLog('──── query result ────');
      _iapLog('elapsedMs=${sw.elapsedMilliseconds}');
      _iapLog('foundCount=${found.length}');
      _iapLog('notFoundCount=${response.notFoundIDs.length}');
      _iapLog('hasError=${response.error != null}');
      _logIapError(response.error);

      if (response.notFoundIDs.isNotEmpty) {
        _iapLog('──── notFoundIDs (ASC does not return these) ────');
        for (final id in response.notFoundIDs) {
          _iapLog('  NOT_FOUND $id');
        }
      }

      if (found.isNotEmpty) {
        _iapLog('──── found products ────');
        for (final p in found) {
          _iapLog(
            '  FOUND id=${p.id} price=${p.price} '
            'currencyCode=${p.currencyCode} rawPrice=${p.rawPrice} '
            'title="${p.title}" description="${p.description}"',
          );
        }
        final missing = productIds.difference(found.map((p) => p.id).toSet());
        if (missing.isNotEmpty) {
          _iapLog('──── requested but missing ────');
          for (final id in missing) {
            _iapLog('  MISSING $id');
          }
        }
        final plans = <ProPlan>[
          for (final product in found)
            ProPlan(
              id: product.id,
              title: product.title,
              price: product.price,
              isAnnual: _isAnnualProduct(product.id),
              tier: tierFromProductId(product.id),
              aiEnabled: () {
                final t = tierFromProductId(product.id);
                return t == PlanTier.pro || t == PlanTier.studio;
              }(),
              product: product,
            ),
        ];
        plans.sort((a, b) => _rank(b).compareTo(_rank(a)));
        lastCatalogError = null;
        _iapLog('OK returning ${plans.length} store plans (no fake catalog)');
        return plans;
      }

      final errCode = response.error?.code ?? 'empty';
      final errMsg = response.error?.message ?? 'zero products';
      _setCatalogError(
        'catalog_empty: code=$errCode message=$errMsg '
        'requested=${ids.join(',')} '
        'notFound=${response.notFoundIDs.join(',')}',
      );
      return const [];
    } catch (e, st) {
      _iapLog('loadPlans EXCEPTION: $e');
      _iapLog('$st');
      _setCatalogError('catalog_exception: $e');
      return const [];
    }
  }

  bool _matchesPendingPurchase(PurchaseDetails purchase) {
    final pending = _pendingProductId;
    if (pending == null || pending.isEmpty) return true;
    if (purchase.productID == pending) return true;
    // Sheet dismiss sometimes arrives under the sibling period SKU.
    if (purchase.status == PurchaseStatus.canceled &&
        tierFromProductId(purchase.productID) ==
            tierFromProductId(pending) &&
        tierFromProductId(pending) != PlanTier.free) {
      return true;
    }
    return false;
  }

  void _onPurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      final waiting = _purchaseCompleter != null &&
          !_purchaseCompleter!.isCompleted;
      if (waiting && _matchesPendingPurchase(purchase)) {
        if (purchase.status == PurchaseStatus.pending) {
          _iapLog(
            'purchase pending sheet product=${purchase.productID} '
            'waitingFor=$_pendingProductId',
          );
          continue;
        }
        _iapLog(
          'purchase stream resolve status=${purchase.status.name} '
          'product=${purchase.productID} waitingFor=$_pendingProductId',
        );
        _purchaseCompleter!.complete(purchase);
        continue;
      }

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        if (_iapSyncActive) {
          // Launch / restore: trust StoreKit product ownership locally.
          final fromStore = tierFromProductId(purchase.productID);
          final candidateRank = _tierRank(fromStore) * 2 +
              (_isAnnualProduct(purchase.productID) ? 1 : 0);
          final bestRank = _tierRank(_iapSyncBest) * 2 +
              ((_iapSyncBestProductId != null &&
                      _isAnnualProduct(_iapSyncBestProductId!))
                  ? 1
                  : 0);
          if (candidateRank >= bestRank) {
            _iapSyncBest = fromStore;
            _iapSyncBestProductId = purchase.productID;
          }
          unawaited(
            _applyTier(
              fromStore,
              allowDowngrade: false,
              productId: purchase.productID,
            ),
          );
          // Keep server in sync, but never let an expired Sandbox JWS wipe Plus.
          unawaited(_verifyAndFinish(purchase, allowDowngrade: false));
        } else {
          // Unsolicited redelivery — finish only; entitlement already from launch.
          _iapLog(
            'complete-only unsolicited ${purchase.status.name} '
            'product=${purchase.productID} '
            'waitingFor=${waiting ? _pendingProductId : '-'}',
          );
          if (purchase.pendingCompletePurchase) {
            unawaited(_iap.completePurchase(purchase));
          }
        }
        continue;
      }

      if (purchase.pendingCompletePurchase) {
        unawaited(_iap.completePurchase(purchase));
      }
    }
  }

  Future<ProPurchaseResult> purchase(ProPlan plan) async {
    _iapLog('purchase start id=${plan.id} product=${plan.product?.id}');

    final product = plan.product;
    if (!_storeConfigured || product == null) {
      _iapLog(
        'purchase unavailable storeConfigured=$_storeConfigured '
        'productNull=${product == null} lastCatalogError=$lastCatalogError',
      );
      return ProPurchaseResult.unavailable;
    }
    if (isPurchaseInFlight) {
      _iapLog(
        'purchase blocked — already in flight '
        'pending=$_pendingProductId requested=${product.id}',
      );
      return ProPurchaseResult.failed;
    }
    if (!canPurchase(plan)) {
      _iapLog(
        'purchase blocked kind=${changeKindFor(plan).name} plan=${plan.id}',
      );
      return changeKindFor(plan) == PlanChangeKind.current
          ? ProPurchaseResult.purchased
          : ProPurchaseResult.unavailable;
    }

    final completer = Completer<PurchaseDetails?>();
    _purchaseCompleter = completer;
    _pendingProductId = product.id;
    try {
      final param = PurchaseParam(productDetails: product);
      final started = await _iap.buyNonConsumable(purchaseParam: param);
      _iapLog('buyNonConsumable started=$started product=${product.id}');
      if (!started) {
        return ProPurchaseResult.failed;
      }
      // Upgrades can stall if StoreKit only redelivers the old SKU; fail fast
      // instead of spinning on the paywall for minutes.
      final details = await completer.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          _iapLog(
            'purchase timeout waitingFor=$_pendingProductId '
            '(no matching stream event)',
          );
          return null;
        },
      );
      if (details == null) return ProPurchaseResult.failed;
      if (details.status == PurchaseStatus.canceled) {
        if (details.pendingCompletePurchase) {
          await _iap.completePurchase(details);
        }
        return ProPurchaseResult.cancelled;
      }
      if (details.status == PurchaseStatus.error) {
        debugPrint('[ProService] purchase error: ${details.error}');
        if (details.pendingCompletePurchase) {
          await _iap.completePurchase(details);
        }
        return ProPurchaseResult.failed;
      }
      final ok = await _verifyAndFinish(details, allowDowngrade: true);
      return ok ? ProPurchaseResult.purchased : ProPurchaseResult.failed;
    } catch (e) {
      debugPrint('[ProService] purchase failed: $e');
      return ProPurchaseResult.failed;
    } finally {
      if (identical(_purchaseCompleter, completer)) {
        _pendingProductId = null;
        _purchaseCompleter = null;
      }
    }
  }

  Future<bool> restore() async {
    await ensureInitialized();
    if (!_storeConfigured) {
      await refreshEntitlementFromServer();
      return isPro;
    }
    _iapSyncActive = true;
    _iapSyncBest = PlanTier.free;
    _iapSyncBestProductId = null;
    try {
      await _iap.restorePurchases();
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_tierRank(_iapSyncBest) > _tierRank(_storeTier) ||
          (_iapSyncBest == _storeTier &&
              _iapSyncBestProductId != null &&
              _iapSyncBestProductId != _activeProductId)) {
        await _setStoreTier(
          _iapSyncBest,
          productId: _iapSyncBestProductId,
        );
      }
      final iapTier = _storeTier;
      final iapProduct = _activeProductId;
      await refreshEntitlementFromServer();
      final loggedIn = ApiService.shared.token?.isNotEmpty == true;
      if (loggedIn && _tierRank(_storeTier) < _tierRank(iapTier)) {
        await _setStoreTier(iapTier, productId: iapProduct);
      }
    } catch (e) {
      debugPrint('[ProService] restore failed: $e');
    } finally {
      _iapSyncActive = false;
    }
    return isPro;
  }

  Future<bool> _verifyAndFinish(
    PurchaseDetails purchase, {
    bool allowDowngrade = true,
  }) async {
    try {
      final verified = await _verifyWithServer(
        purchase,
        allowDowngrade: allowDowngrade,
      );
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      return verified;
    } catch (e) {
      debugPrint('[ProService] verify/finish failed: $e');
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      return false;
    }
  }

  Future<bool> _verifyWithServer(
    PurchaseDetails purchase, {
    required bool allowDowngrade,
  }) async {
    await CreditService.instance.ensureInitialized();
    final deviceKey = await CreditService.instance.deviceKey();
    final api = ApiService.shared;
    await api.ensureAuthToken();
    final token = api.token;
    if (token == null || token.isEmpty) {
      _iapLog('verify aborted — app account (Firebase) token required');
      return false;
    }

    final platform = Platform.isIOS ? 'ios' : 'android';
    final body = <String, dynamic>{
      'deviceKey': deviceKey,
      'platform': platform,
      'productId': purchase.productID,
    };
    if (platform == 'ios') {
      body['verificationData'] =
          purchase.verificationData.serverVerificationData;
      // Local verification data sometimes holds the transaction id / JWS too.
      if ((body['verificationData'] as String?)?.isEmpty ?? true) {
        body['verificationData'] =
            purchase.verificationData.localVerificationData;
      }
      if (purchase.purchaseID != null) {
        body['transactionId'] = purchase.purchaseID;
      }
    } else {
      body['purchaseToken'] =
          purchase.verificationData.serverVerificationData;
    }

    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer $token',
    };

    _iapLog(
      'verify → server platform=$platform product=${purchase.productID} '
      'status=${purchase.status} purchaseID=${purchase.purchaseID} '
      'deviceKey=${deviceKey.substring(0, deviceKey.length.clamp(0, 8))}… '
      'auth=yes',
    );
    final res = await http.post(
      Uri.parse('${CreditService.baseUrl}/api/subscriptions/verify'),
      headers: headers,
      body: jsonEncode(body),
    );
    final bodyText = utf8.decode(res.bodyBytes);
    _iapLog('verify ← ${res.statusCode} $bodyText');
    if (res.statusCode == 400) {
      try {
        final err = jsonDecode(bodyText);
        if (err is Map) {
          _iapLog(
            'verify detail jwsError=${err['jwsError']} '
            'lookupError=${err['lookupError']}',
          );
        }
      } catch (_) {}
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = jsonDecode(bodyText);
      if (map is Map) {
        final tier = _parseTier(map['planTier'] as String?) ??
            tierFromProductId(purchase.productID);
        final productId =
            (map['productId'] as String?)?.trim() ?? purchase.productID;
        await _applyTier(
          tier,
          allowDowngrade: allowDowngrade,
          productId: productId,
        );
        return _tierRank(tier) > 0 || _tierRank(_storeTier) > 0;
      }
    } else {
      _iapLog(
        'verify failed — keeping current tier '
        '(status=${res.statusCode} local=${_storeTier.name})',
      );
    }
    return _tierRank(_storeTier) > 0;
  }

  /// Debug-only switch on the paywall (maps to Pro monthly when on).
  Future<void> setDebugPro(bool enabled) async {
    if (enabled) {
      await setDebugSubscription(PlanTier.pro, annual: false);
    } else {
      await clearDebugSubscription();
    }
  }

  Future<void> setDebugTier(PlanTier tier) async {
    if (tier == PlanTier.free) {
      await clearDebugSubscription();
      return;
    }
    await setDebugSubscription(tier, annual: _debugAnnual ?? false);
  }

  /// Force a fake entitlement for paywall UI testing (debug builds only).
  Future<void> setDebugSubscription(
    PlanTier tier, {
    required bool annual,
  }) async {
    if (!kDebugMode) return;
    if (tier == PlanTier.free) {
      await clearDebugSubscription();
      return;
    }
    _debugTier = tier;
    _debugAnnual = annual;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugProKey, true);
    await prefs.setString(_debugTierKey, tier.name);
    await prefs.setBool(_debugAnnualKey, annual);
    notifyListeners();
  }

  Future<void> clearDebugSubscription() async {
    if (!kDebugMode) return;
    _debugTier = PlanTier.free;
    _debugAnnual = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugProKey, false);
    await prefs.setString(_debugTierKey, PlanTier.free.name);
    await prefs.remove(_debugAnnualKey);
    notifyListeners();
  }
}
