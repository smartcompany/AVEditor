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

/// EasyClip subscription state (Plus / Pro / Studio) via native IAP.
///
/// Store Product IDs come from the dashboard plan config
/// (`storeProductIdMonthly` / `storeProductIdAnnual`).
///
/// Server (`/api/subscriptions/*`) is the entitlement source of truth after
/// purchase/restore. Empty store catalog → paywall shows an error (no fake prices).
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
  static const _cachedTierKey = 'store_plan_tier';

  final InAppPurchase _iap = InAppPurchase.instance;

  bool _initialized = false;
  bool _storeConfigured = false;
  PlanTier _storeTier = PlanTier.free;
  PlanTier _debugTier = PlanTier.free;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  Completer<PurchaseDetails?>? _purchaseCompleter;
  String? _pendingProductId;

  /// True when editing unlock is active (Plus / Pro / Studio / debug).
  bool get isPro =>
      _storeTier != PlanTier.free ||
      (kDebugMode && _debugTier != PlanTier.free);

  PlanTier get tier {
    if (_storeTier != PlanTier.free) return _storeTier;
    if (kDebugMode) return _debugTier;
    return PlanTier.free;
  }

  bool get aiEnabled =>
      tier == PlanTier.pro || tier == PlanTier.studio;

  bool get storeAvailable => _storeConfigured;

  bool get debugProEnabled => _debugTier != PlanTier.free;

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
    }
    final cached = _parseTier(prefs.getString(_cachedTierKey));
    if (cached != null) _storeTier = cached;

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

    unawaited(refreshEntitlementFromServer());
    notifyListeners();
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

  Future<void> _setStoreTier(PlanTier next) async {
    if (_storeTier == next) return;
    _storeTier = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedTierKey, next.name);
    notifyListeners();
  }

  Future<void> refreshEntitlementFromServer() async {
    try {
      await CreditService.instance.ensureInitialized();
      final deviceKey = await CreditService.instance.deviceKey();
      final api = ApiService.shared;
      await api.ensureAuthToken(); // optional — ignore failure
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      };
      final token = api.token;
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final uri = Uri.parse(
        '${CreditService.baseUrl}/api/subscriptions/me',
      ).replace(queryParameters: {'deviceKey': deviceKey});
      final res = await http.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        if (map is Map) {
          final tier = _parseTier(map['planTier'] as String?) ?? PlanTier.free;
          await _setStoreTier(tier);
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

  void _onPurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      if (_purchaseCompleter != null &&
          !_purchaseCompleter!.isCompleted &&
          (_pendingProductId == null ||
              purchase.productID == _pendingProductId)) {
        if (purchase.status == PurchaseStatus.pending) continue;
        _purchaseCompleter!.complete(purchase);
      } else if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        // Deliver outside an explicit purchase() await (e.g. restore).
        unawaited(_verifyAndFinish(purchase));
      } else if (purchase.pendingCompletePurchase) {
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

    _purchaseCompleter = Completer<PurchaseDetails?>();
    _pendingProductId = product.id;
    try {
      final param = PurchaseParam(productDetails: product);
      final started = await _iap.buyNonConsumable(purchaseParam: param);
      if (!started) {
        return ProPurchaseResult.failed;
      }
      final details = await _purchaseCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => null,
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
      final ok = await _verifyAndFinish(details);
      return ok ? ProPurchaseResult.purchased : ProPurchaseResult.failed;
    } catch (e) {
      debugPrint('[ProService] purchase failed: $e');
      return ProPurchaseResult.failed;
    } finally {
      _pendingProductId = null;
      _purchaseCompleter = null;
    }
  }

  Future<bool> restore() async {
    await ensureInitialized();
    if (!_storeConfigured) {
      await refreshEntitlementFromServer();
      return isPro;
    }
    try {
      await _iap.restorePurchases();
      // Give the purchase stream a moment to deliver restored items.
      await Future<void>.delayed(const Duration(seconds: 2));
      await refreshEntitlementFromServer();
    } catch (e) {
      debugPrint('[ProService] restore failed: $e');
    }
    return isPro;
  }

  Future<bool> _verifyAndFinish(PurchaseDetails purchase) async {
    try {
      final verified = await _verifyWithServer(purchase);
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

  Future<bool> _verifyWithServer(PurchaseDetails purchase) async {
    await CreditService.instance.ensureInitialized();
    final deviceKey = await CreditService.instance.deviceKey();
    final api = ApiService.shared;
    await api.ensureAuthToken(); // optional

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
    };
    final token = api.token;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    _iapLog(
      'verify → server platform=$platform product=${purchase.productID} '
      'status=${purchase.status} purchaseID=${purchase.purchaseID} '
      'deviceKey=${deviceKey.substring(0, deviceKey.length.clamp(0, 8))}…',
    );
    final res = await http.post(
      Uri.parse('${CreditService.baseUrl}/api/subscriptions/verify'),
      headers: headers,
      body: jsonEncode(body),
    );
    final bodyText = utf8.decode(res.bodyBytes);
    _iapLog('verify ← ${res.statusCode} $bodyText');
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = jsonDecode(bodyText);
      if (map is Map) {
        final tier = _parseTier(map['planTier'] as String?) ??
            tierFromProductId(purchase.productID);
        await _setStoreTier(tier);
        return tier != PlanTier.free;
      }
    } else {
      // Do not unlock locally on verify failure — otherwise the paywall
      // looks "purchased" until the next entitlement refresh resets to free.
      _iapLog(
        'verify failed — keeping locked until server accepts the receipt '
        '(status=${res.statusCode})',
      );
    }
    return false;
  }

  /// Debug-only switch on the paywall (maps to Pro tier when on).
  Future<void> setDebugPro(bool enabled) async {
    await setDebugTier(enabled ? PlanTier.pro : PlanTier.free);
  }

  Future<void> setDebugTier(PlanTier tier) async {
    if (!kDebugMode) return;
    _debugTier = tier;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugProKey, tier != PlanTier.free);
    await prefs.setString(_debugTierKey, tier.name);
    notifyListeners();
  }
}
