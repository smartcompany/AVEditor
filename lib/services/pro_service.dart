import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One purchasable Pro plan as shown on the paywall.
class ProPlan {
  const ProPlan({
    required this.id,
    required this.title,
    required this.price,
    required this.isAnnual,
    this.package,
  });

  final String id;
  final String title;
  final String price;
  final bool isAnnual;

  /// RevenueCat package backing this plan (null in dev mode).
  final Package? package;
}

enum ProPurchaseResult { purchased, cancelled, failed, unavailable }

/// AVEditor Pro subscription state.
///
/// Backed by RevenueCat when an API key is provided at build time:
///   flutter run --dart-define=RC_IOS_KEY=appl_xxx --dart-define=RC_ANDROID_KEY=goog_xxx
/// The entitlement checked is [entitlementId] ("pro").
///
/// Without a key the store is "unavailable"; debug builds can still flip a
/// local test switch so the Pro flow can be exercised before store setup.
class ProService extends ChangeNotifier {
  ProService._();

  static final ProService instance = ProService._();

  static const entitlementId = 'pro';
  static const _iosKey = String.fromEnvironment('RC_IOS_KEY');
  static const _androidKey = String.fromEnvironment('RC_ANDROID_KEY');
  static const _debugProKey = 'debug_pro_enabled';

  bool _initialized = false;
  bool _storeConfigured = false;
  bool _storePro = false;
  bool _debugPro = false;

  /// True when the user may use Pro features.
  bool get isPro => _storePro || (kDebugMode && _debugPro);

  /// True when purchases can actually be made (RevenueCat configured).
  bool get storeAvailable => _storeConfigured;

  /// Local test switch (debug builds only).
  bool get debugProEnabled => _debugPro;

  String get _apiKey {
    if (kIsWeb) return '';
    if (Platform.isIOS || Platform.isMacOS) return _iosKey;
    if (Platform.isAndroid) return _androidKey;
    return '';
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    if (kDebugMode) {
      final prefs = await SharedPreferences.getInstance();
      _debugPro = prefs.getBool(_debugProKey) ?? false;
    }
    final key = _apiKey;
    if (key.isNotEmpty) {
      try {
        await Purchases.configure(PurchasesConfiguration(key));
        Purchases.addCustomerInfoUpdateListener(_applyCustomerInfo);
        _storeConfigured = true;
        _applyCustomerInfo(await Purchases.getCustomerInfo());
      } on PlatformException catch (e) {
        debugPrint('[ProService] RevenueCat setup failed: $e');
      }
    }
    notifyListeners();
  }

  void _applyCustomerInfo(CustomerInfo info) {
    final active = info.entitlements.active.containsKey(entitlementId);
    if (active != _storePro) {
      _storePro = active;
      notifyListeners();
    }
  }

  /// Plans from the current RevenueCat offering, annual first.
  Future<List<ProPlan>> loadPlans() async {
    if (!_storeConfigured) return const [];
    try {
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      if (current == null) return const [];
      final plans = <ProPlan>[];
      for (final package in current.availablePackages) {
        final annual = package.packageType == PackageType.annual;
        plans.add(
          ProPlan(
            id: package.identifier,
            title: package.storeProduct.title,
            price: package.storeProduct.priceString,
            isAnnual: annual,
            package: package,
          ),
        );
      }
      plans.sort((a, b) => (b.isAnnual ? 1 : 0) - (a.isAnnual ? 1 : 0));
      return plans;
    } on PlatformException catch (e) {
      debugPrint('[ProService] offerings failed: $e');
      return const [];
    }
  }

  Future<ProPurchaseResult> purchase(ProPlan plan) async {
    final package = plan.package;
    if (!_storeConfigured || package == null) {
      return ProPurchaseResult.unavailable;
    }
    try {
      final result = await Purchases.purchase(PurchaseParams.package(package));
      _applyCustomerInfo(result.customerInfo);
      return isPro ? ProPurchaseResult.purchased : ProPurchaseResult.failed;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        return ProPurchaseResult.cancelled;
      }
      debugPrint('[ProService] purchase failed: $e');
      return ProPurchaseResult.failed;
    }
  }

  /// Restores earlier purchases; returns whether Pro is active afterwards.
  Future<bool> restore() async {
    if (!_storeConfigured) return isPro;
    try {
      _applyCustomerInfo(await Purchases.restorePurchases());
    } on PlatformException catch (e) {
      debugPrint('[ProService] restore failed: $e');
    }
    return isPro;
  }

  /// Debug-only switch so the Pro flow can be tested without a store.
  Future<void> setDebugPro(bool enabled) async {
    if (!kDebugMode) return;
    _debugPro = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugProKey, enabled);
    notifyListeners();
  }
}
