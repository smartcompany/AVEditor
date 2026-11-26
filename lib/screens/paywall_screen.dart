import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/auth_helper.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Subscription paywall (Plus / Pro / Studio). Pops `true` when a paid plan
/// is active on exit.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({
    super.key,
    this.pro,
    this.source = 'settings',
    this.preferAnnual = false,
    this.initialPlans,
  });

  final ProService? pro;
  final String source;
  /// Initial billing period tab. Falls back if that period has no plans.
  final bool preferAnnual;

  /// Preloaded store plans from [open]. When set, the screen skips the
  /// catalog fetch and never paints l10n placeholder copy.
  final List<ProPlan>? initialPlans;

  /// Shows a centered waiting overlay, loads store + dashboard copy, then
  /// opens the paywall only when that data is ready (no dummy flash).
  static Future<bool> open(
    BuildContext context, {
    String source = 'settings',
    bool? preferAnnual,
  }) async {
    final annualTab =
        preferAnnual ?? ProService.instance.activeIsAnnual ?? false;
    final nav = Navigator.of(context, rootNavigator: true);
    var waitingVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      barrierColor: Colors.black54,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          ),
        ),
      ),
    );

    List<ProPlan> plans = const [];
    final pro = ProService.instance;
    try {
      await pro.ensureInitialized();
      await CreditService.instance.ensureInitialized();
      await CreditService.instance.ensurePlansLoaded();
      plans = _enabledStorePlans(await pro.loadPlans());
      AnalyticsService.instance.log('paywall_catalog', {
        'source': source,
        'count': plans.length,
        'store_available': pro.storeAvailable,
        if (pro.lastCatalogError != null) 'catalog_error': pro.lastCatalogError,
      });
    } finally {
      if (waitingVisible && context.mounted) {
        nav.pop();
        waitingVisible = false;
      }
    }

    if (!context.mounted) return pro.isPro;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallScreen(
          source: source,
          preferAnnual: annualTab,
          initialPlans: plans,
        ),
      ),
    );
    return result ?? pro.isPro;
  }

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

/// Hide paid tiers the dashboard marked as disabled.
List<ProPlan> _enabledStorePlans(List<ProPlan> plans) {
  final credits = CreditService.instance;
  final remote = credits.plans;
  if (remote.isEmpty) return plans;
  return [
    for (final plan in plans)
      if (plan.tier == PlanTier.free ||
          (credits.planById(_tierIdForPlan(plan.tier))?.enabled ?? false))
        plan,
  ];
}

String _tierIdForPlan(PlanTier tier) => switch (tier) {
      PlanTier.plus => 'plus',
      PlanTier.studio => 'studio',
      PlanTier.pro || PlanTier.free => 'pro',
    };

class _PaywallScreenState extends State<PaywallScreen> {
  ProService get _pro => widget.pro ?? ProService.instance;

  List<ProPlan> _plans = const [];
  ProPlan? _selected;
  late bool _annual = widget.preferAnnual;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pro.addListener(_onProChanged);
    AnalyticsService.instance.log('paywall_open', {'source': widget.source});
    final preloaded = widget.initialPlans;
    if (preloaded != null) {
      _applyPlans(preloaded);
    } else {
    _load();
    }
  }

  @override
  void dispose() {
    _pro.removeListener(_onProChanged);
    super.dispose();
  }

  void _onProChanged() {
    if (!mounted) return;
    setState(() {
      // Re-highlight after debug preset / restore changes entitlement.
      if (_plans.isNotEmpty) {
        _selected = _pickDefault(_plans, annual: _annual);
      }
    });
  }

  void _applyPlans(List<ProPlan> plans) {
    final hasAnnual = plans.any((p) => p.isAnnual);
    final hasMonthly = plans.any((p) => !p.isAnnual);
    final preferAnnual = widget.preferAnnual;
    final useAnnual = preferAnnual
        ? (hasAnnual || !hasMonthly)
        : (hasMonthly ? false : hasAnnual);
    _plans = plans;
    _annual = useAnnual;
    _selected = _pickDefault(plans, annual: _annual);
    _loading = false;
  }

  Future<void> _load() async {
    await _pro.ensureInitialized();
    await CreditService.instance.ensureInitialized();
    await CreditService.instance.ensurePlansLoaded();
    final plans = _enabledStorePlans(await _pro.loadPlans());
    if (!mounted) return;
    setState(() => _applyPlans(plans));
    AnalyticsService.instance.log('paywall_catalog', {
      'source': widget.source,
      'count': plans.length,
      'store_available': _pro.storeAvailable,
      if (_pro.lastCatalogError != null) 'catalog_error': _pro.lastCatalogError,
    });
  }

  ProPlan? _pickDefault(List<ProPlan> plans, {required bool annual}) {
    final filtered = _sortedPlans(
      plans.where((p) => p.isAnnual == annual),
    );
    if (filtered.isEmpty) {
      final all = _sortedPlans(plans);
      return all.isEmpty ? null : all.first;
    }
    // Prefer the plan the user already owns on this billing tab.
    for (final p in filtered) {
      if (_pro.isCurrentPlan(p)) return p;
    }
    // Same-tier upgrade (e.g. Pro monthly → Pro yearly).
    for (final p in filtered) {
      if (_pro.changeKindFor(p) == PlanChangeKind.upgrade &&
          p.tier == _pro.tier) {
        return p;
      }
    }
    // Any upgrade (e.g. Pro → Studio).
    for (final p in filtered) {
      if (_pro.changeKindFor(p) == PlanChangeKind.upgrade) return p;
    }
    // New subscribers: Plus → Pro → Studio.
    for (final tier in [PlanTier.plus, PlanTier.pro, PlanTier.studio]) {
      for (final p in filtered) {
        if (p.tier == tier) return p;
      }
    }
    return filtered.first;
  }

  List<ProPlan> get _visiblePlans {
    final filtered = _plans.where((p) => p.isAnnual == _annual);
    final sorted = _sortedPlans(filtered);
    if (sorted.isNotEmpty) return sorted;
    return _sortedPlans(_plans);
  }

  bool _isOwnedDisplay(ProPlan plan) {
    final kind = _pro.changeKindFor(plan);
    // Same-tier yearly → monthly stays visible but acts like current
    // (not purchasable).
    return kind == PlanChangeKind.current ||
        kind == PlanChangeKind.periodDowngradeBlocked;
  }

  ProPlan? get _currentPlan {
    for (final p in _plans) {
      if (_pro.isCurrentPlan(p)) return p;
    }
    return null;
  }

  List<ProPlan> _sortedPlans(Iterable<ProPlan> plans) {
    final list = plans.toList();
    list.sort((a, b) => _tierRank(a.tier).compareTo(_tierRank(b.tier)));
    return list;
  }

  int _tierRank(PlanTier tier) => switch (tier) {
        PlanTier.plus => 0,
        PlanTier.pro => 1,
        PlanTier.studio => 2,
        PlanTier.free => 3,
      };

  bool get _hasBillingChoice {
    final annual = _plans.any((p) => p.isAnnual);
    final monthly = _plans.any((p) => !p.isAnnual);
    return annual && monthly;
  }

  void _setAnnual(bool annual) {
    if (_annual == annual) return;
    setState(() {
      _annual = annual;
      final tier = _selected?.tier;
      final match = _visiblePlans.cast<ProPlan?>().firstWhere(
            (p) => p!.tier == tier,
            orElse: () => _pickDefault(_plans, annual: annual),
          );
      _selected = match;
    });
  }

  void _close() => Navigator.of(context).pop(_pro.isPro);

  bool _isOneStepSamePeriodUpgrade(ProPlan plan) {
    if (_pro.changeKindFor(plan) != PlanChangeKind.upgrade) return false;
    final annual = _pro.activeIsAnnual;
    if (annual == null || plan.isAnnual != annual) return false;
    return _tierRank(plan.tier) - _tierRank(_pro.tier) == 1;
  }

  void _paywallLog(String message) {
    debugPrint('[Paywall] $message');
  }

  /// Subscriptions are tied to the EasyClip account (Firebase uid).
  Future<bool> _ensureLoggedIn() async {
    _paywallLog('auth gate → requireAuth');
    final ok = await AuthHelper.requireAuth(context);
    if (!ok || !mounted) {
      _paywallLog('auth gate aborted ok=$ok mounted=$mounted');
      return false;
    }
    _paywallLog(
      'auth ok → refresh entitlement '
      '(tier=${_pro.tier.name} annual=${_pro.activeIsAnnual} '
      'product=${_pro.activeProductId ?? '-'})',
    );
    await _pro.refreshEntitlementFromServer();
    if (!mounted) {
      _paywallLog('auth gate aborted — unmounted after refresh');
      return false;
    }
    _paywallLog(
      'entitlement after refresh '
      'tier=${_pro.tier.name} annual=${_pro.activeIsAnnual} '
      'product=${_pro.activeProductId ?? '-'} '
      'debug=${_pro.debugPreset}',
    );
    setState(() {
      if (_plans.isNotEmpty) {
        _selected = _pickDefault(_plans, annual: _annual);
      }
    });
    return true;
  }

  Future<void> _subscribe(ProPlan plan) async {
    final kind = _pro.changeKindFor(plan);
    _paywallLog(
      'subscribe tap id=${plan.id} tier=${plan.tier.name} '
      'annual=${plan.isAnnual} price=${plan.price} '
      'kind=$kind canPurchase=${_pro.canPurchase(plan)} '
      'busy=$_busy inFlight=${_pro.isPurchaseInFlight} '
      'productNull=${plan.product == null} '
      'storeAvailable=${_pro.storeAvailable}',
    );
    if (_busy || _pro.isPurchaseInFlight) {
      _paywallLog('subscribe aborted — busy/inFlight');
      return;
    }
    if (!_pro.canPurchase(plan)) {
      _paywallLog('subscribe aborted — canPurchase=false kind=$kind');
      return;
    }

    setState(() {
      _busy = true;
      _selected = plan;
    });
    try {
      if (!await _ensureLoggedIn()) {
        _paywallLog('subscribe aborted — login required/cancelled');
        return;
      }
      final kindAfterLogin = _pro.changeKindFor(plan);
      if (!_pro.canPurchase(plan)) {
        // Account already owns this (or a higher) plan after login sync.
        _paywallLog(
          'subscribe aborted after login — canPurchase=false '
          'kind=$kindAfterLogin tier=${_pro.tier.name}',
        );
        return;
      }

      if (_isOneStepSamePeriodUpgrade(plan)) {
        _paywallLog('showing upgrade confirm sheet');
        // Let the confirm sheet sit above a quiet paywall.
        if (mounted) setState(() => _busy = false);
        final confirmed = await _showUpgradeConfirm(plan);
        if (!confirmed || !mounted) {
          _paywallLog(
            'upgrade confirm cancelled confirmed=$confirmed mounted=$mounted',
          );
          return;
        }
    setState(() => _busy = true);
      }

      _paywallLog('starting store purchase…');
      await _runPurchase(plan);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<bool> _showUpgradeConfirm(ProPlan target) async {
    final l10n = context.l10n;
    final current = _currentPlan;
    final targetLabel = _tierLabel(context, l10n, target.tier);
    final currentLabel = _tierLabel(context, l10n, _pro.tier);
    final period = target.isAnnual
        ? l10n.planBillingAnnual
        : l10n.planBillingMonthly;
    final currentPrice = current?.price ?? '—';
    final currentDetail = l10n.planUpgradePriceDetail(
      currentLabel,
      currentPrice,
      period,
    );
    final targetDetail = l10n.planUpgradePriceDetail(
      targetLabel,
      target.price,
      period,
    );

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _UpgradeConfirmSheet(
          title: l10n.planUpgradeSheetTitle(targetLabel),
          subtitle: _subtitleFor(sheetContext, l10n, target.tier),
          todayLabel: l10n.planUpgradeToday,
          afterLabel: l10n.planUpgradeAfter,
          todayDetail: currentDetail,
          afterDetail: targetDetail,
          todayPrice: currentPrice,
          afterPrice: target.price,
          continueLabel: l10n.planUpgradeContinue,
          legal: l10n.planUpgradeLegal,
        );
      },
    );
    return result == true;
  }

  Future<void> _runPurchase(ProPlan plan) async {
    final kind = _pro.changeKindFor(plan);
    // Store charges Apple/Google; entitlement is stored under the app account.
    // Caller owns `_busy` overlay for the whole subscribe flow.
    _paywallLog('purchase() call kind=$kind id=${plan.id}');
    final result = await _pro.purchase(plan);
    if (!mounted) {
      _paywallLog('purchase finished but unmounted result=$result');
      return;
    }
    _paywallLog('purchase result=$result id=${plan.id}');
    final analytics = AnalyticsService.instance;
    switch (result) {
      case ProPurchaseResult.purchased:
        analytics.log('purchase_success', {
          'plan': plan.id,
          'annual': plan.isAnnual,
          'tier': plan.tier.name,
          'change': kind.name,
        });
        _close();
      case ProPurchaseResult.cancelled:
        analytics.log('purchase_cancelled', {'plan': plan.id});
      case ProPurchaseResult.failed:
      case ProPurchaseResult.unavailable:
        analytics.log('purchase_failed', {
          'plan': plan.id,
          if (_pro.lastCatalogError != null)
            'catalog_error': _pro.lastCatalogError,
        });
        _snack(context.l10n.proPurchaseFailed);
    }
  }

  Future<void> _restore() async {
    _paywallLog('restore tap busy=$_busy');
    if (_busy) {
      _paywallLog('restore aborted — busy');
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await _ensureLoggedIn()) {
        _paywallLog('restore aborted — login required/cancelled');
        return;
      }
      _paywallLog('restore() call…');
    final active = await _pro.restore();
    if (!mounted) return;
      _paywallLog(
        'restore done active=$active tier=${_pro.tier.name} '
        'product=${_pro.activeProductId ?? '-'}',
      );
    if (active) {
      AnalyticsService.instance.log('restore_success');
      _close();
    } else {
      _snack(context.l10n.proRestoreNone);
      }
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    showLoggedSnackBar(context, message);
  }

  String _lang(BuildContext context) =>
      Localizations.localeOf(context).languageCode;

  String _tierId(PlanTier tier) => switch (tier) {
        PlanTier.plus => 'plus',
        PlanTier.studio => 'studio',
        PlanTier.pro || PlanTier.free => 'pro',
      };

  int _monthlyCredits(PlanTier tier) =>
      CreditService.instance.monthlyCreditsFor(_tierId(tier));

  String _subtitleFor(
    BuildContext context,
    AppLocalizations l10n,
    PlanTier tier,
  ) {
    final n = _monthlyCredits(tier);
    final remote = CreditService.instance.planById(_tierId(tier));
    if (remote != null) {
      final text = remote.localizedSubtitle(_lang(context), credits: n);
      if (text.isNotEmpty) return text;
    }
    return switch (tier) {
      PlanTier.plus => l10n.planPlusSubtitle(n),
      PlanTier.studio => l10n.planStudioSubtitle(n),
      PlanTier.pro || PlanTier.free => l10n.planProSubtitle(n),
    };
  }

  List<String> _benefitsFor(
    BuildContext context,
    AppLocalizations l10n,
    PlanTier tier,
  ) {
    final n = _monthlyCredits(tier);
    final remote = CreditService.instance.planById(_tierId(tier));
    if (remote != null) {
      final list = remote.localizedBenefits(_lang(context), credits: n);
      if (list.isNotEmpty) return list;
    }
    return switch (tier) {
      PlanTier.plus => [
          l10n.planPlusBenefit1(n),
          l10n.planPlusBenefit2,
          l10n.planPlusBenefit3,
        ],
      PlanTier.studio => [
          l10n.planStudioBenefit1(n),
          l10n.planStudioBenefit2,
          l10n.planStudioBenefit3,
          l10n.planStudioBenefit4,
          l10n.planStudioBenefit5,
        ],
      PlanTier.pro || PlanTier.free => [
          l10n.planProBenefit1(n),
          l10n.planProBenefit2,
          l10n.planProBenefit3,
          l10n.planProBenefit4,
        ],
    };
  }

  String _tierLabel(BuildContext context, AppLocalizations l10n, PlanTier tier) {
    final remote = CreditService.instance.planById(_tierId(tier));
    if (remote != null) {
      final name = remote.localizedTitle(_lang(context));
      if (name.isNotEmpty) return name;
    }
    return switch (tier) {
      PlanTier.plus => l10n.planPlusLabel,
      PlanTier.studio => l10n.planStudioLabel,
      PlanTier.pro || PlanTier.free => l10n.planProLabel,
    };
  }

  String _activeStatusText(BuildContext context, AppLocalizations l10n) {
    final plan = _tierLabel(context, l10n, _pro.tier);
    final annual = _pro.activeIsAnnual;
    if (annual == null) return l10n.planActive(plan);
    final period =
        annual ? l10n.planBillingAnnual : l10n.planBillingMonthly;
    return l10n.planActiveWithPeriod(plan, period);
  }

  String? _badgeFor(AppLocalizations l10n, ProPlan plan) {
    if (_isOwnedDisplay(plan)) return l10n.planCurrentSubscription;
    return null;
  }

  String _actionLabelFor(
    BuildContext context,
    AppLocalizations l10n,
    ProPlan plan,
  ) {
    final label = _tierLabel(context, l10n, plan.tier);
    return switch (_pro.changeKindFor(plan)) {
      PlanChangeKind.current ||
      PlanChangeKind.periodDowngradeBlocked =>
        l10n.planCurrentSubscription,
      PlanChangeKind.upgrade => plan.tier == _pro.tier && plan.isAnnual
          ? l10n.planSwitchToAnnual
          : l10n.planUpgradeCta(label),
      PlanChangeKind.downgrade => l10n.planDowngradeCta(label),
      PlanChangeKind.subscribe => l10n.planSubscribeCta(label),
    };
  }

  String? _actionHintFor(
    BuildContext context,
    AppLocalizations l10n,
    ProPlan plan,
  ) {
    if (_pro.changeKindFor(plan) == PlanChangeKind.downgrade) {
      return l10n.planDowngradeHint(_tierLabel(context, l10n, _pro.tier));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final visible = _visiblePlans;
    final compareTiers = <PlanTier>{
      for (final plan in visible) plan.tier,
    }.toList()
      ..sort((a, b) => _tierRank(a).compareTo(_tierRank(b)));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : _close,
          ),
          title: Text(l10n.planChooseTitle),
        ),
        // Never paint title/benefits/prices until the catalog is ready —
        // otherwise l10n fallbacks flash as "dummy" Plus/Pro copy.
        body: DecoratedBox(
          decoration: AppTheme.ambientBackgroundDecoration(),
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : Stack(
                  children: [
                    SafeArea(
          top: false,
          child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
                      if (_pro.isPro && _plans.isEmpty)
                        _StatusCard(text: _activeStatusText(context, l10n))
                      else if (_plans.isEmpty) ...[
                        _StatusCard(text: l10n.proStoreUnavailable),
                        if (kDebugMode &&
                            (_pro.lastCatalogError?.isNotEmpty ?? false))
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(
                              _pro.lastCatalogError!,
                              style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.muted,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                      ] else ...[
                        if (_pro.isPro)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                            child: _StatusCard(
                              text: _activeStatusText(context, l10n),
                            ),
                          ),
                        if (_hasBillingChoice) ...[
                          _BillingToggle(
                            annual: _annual,
                            monthlyLabel: l10n.planBillingMonthly,
                            annualLabel: l10n.planBillingAnnual,
                            saveBadge: l10n.planAnnualSaveBadge,
                            onChanged: _setAnnual,
                          ),
                          const SizedBox(height: 14),
                        ],
                        for (final plan in visible)
                  _PlanTile(
                    plan: plan,
                    selected: plan == _selected,
                            current: _isOwnedDisplay(plan),
                            title: _tierLabel(context, l10n, plan.tier),
                            subtitle:
                                _subtitleFor(context, l10n, plan.tier),
                            benefits:
                                _benefitsFor(context, l10n, plan.tier),
                            badge: _badgeFor(l10n, plan),
                            actionLabel: _actionLabelFor(context, l10n, plan),
                            actionHint: _actionHintFor(context, l10n, plan),
                            actionEnabled:
                                !_busy && _pro.canPurchase(plan),
                            onAction: () => unawaited(_subscribe(plan)),
                          ),
                        if (compareTiers.length >= 2) ...[
                          const SizedBox(height: 28),
                          _PlanCompareTable(
                            tiers: compareTiers,
                            labelFor: (tier) =>
                                _tierLabel(context, l10n, tier),
                            creditsFor: _monthlyCredits,
                            featurePlusEffects: l10n.planComparePlusEffects,
                            featureProEffects: l10n.planCompareProEffects,
                            featureAi: l10n.planCompareAi,
                            featureCredits: l10n.planCompareCredits,
                            featureStudioExtras:
                                l10n.planCompareStudioExtras,
                            title: l10n.planCompareTitle,
                          ),
                        ],
              ],
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _restore,
                child: Text(l10n.proRestore),
              ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.proDebugToggle,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppTheme.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _DebugPlanPresets(
                          selected: _pro.debugPreset,
                          onSelect: (tier, annual) {
                            if (tier != null) {
                              // Align billing tab with the simulated period.
                              _annual = annual;
                            }
                            if (tier == null) {
                              unawaited(_pro.clearDebugSubscription());
                            } else {
                              unawaited(
                                _pro.setDebugSubscription(
                                  tier,
                                  annual: annual,
                                ),
                              );
                            }
                          },
                        ),
                      ],
              const SizedBox(height: 8),
              Text(
                l10n.proLegal,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.muted,
                ),
              ),
            ],
                  ),
                ),
                    if (_busy) const Positioned.fill(child: _BusyOverlay()),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay();

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: const Center(
          child: SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      ),
    );
  }
}

class _BillingToggle extends StatelessWidget {
  const _BillingToggle({
    required this.annual,
    required this.monthlyLabel,
    required this.annualLabel,
    required this.saveBadge,
    required this.onChanged,
  });

  final bool annual;
  final String monthlyLabel;
  final String annualLabel;
  final String saveBadge;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _BillingChip(
                  label: monthlyLabel,
                  selected: !annual,
                  onTap: () => onChanged(false),
                ),
              ),
              Expanded(
                child: _BillingChip(
                  label: annualLabel,
                  selected: annual,
                  onTap: () => onChanged(true),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          saveBadge,
          style: const TextStyle(
            color: AppTheme.accent,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

class _BillingChip extends StatelessWidget {
  const _BillingChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.plan,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.benefits,
    required this.actionLabel,
    required this.actionEnabled,
    required this.onAction,
    this.actionHint,
    this.badge,
    this.current = false,
  });

  final ProPlan plan;
  final bool selected;
  final bool current;
  final String title;
  final String subtitle;
  final List<String> benefits;
  final String? badge;
  final String actionLabel;
  final String? actionHint;
  final bool actionEnabled;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final highlight = selected || current;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2A1B3D), Color(0xFF171022)],
        ),
        border: Border.all(
          color: highlight
              ? AppTheme.accent.withValues(alpha: 0.55)
              : AppTheme.muted.withValues(alpha: 0.38),
          width: 1.2,
        ),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: AppTheme.accent.withValues(alpha: 0.16),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
          child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                Expanded(
                  child: Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                                color: AppTheme.ink,
                              ),
                            ),
                          ),
                          if (badge != null)
                  Container(
                              margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                                borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Text(
                  plan.price,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: AppTheme.ink,
                            ),
                ),
              ],
            ),
                      const SizedBox(height: 2),
                      Text(
                        plan.isAnnual
                            ? context.l10n.planBillingAnnual
                            : context.l10n.planBillingMonthly,
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppTheme.muted,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (benefits.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final benefit in benefits)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(
                          Icons.check_circle,
                          color: AppTheme.accent,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          benefit,
                          style: const TextStyle(
                            color: AppTheme.ink,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (actionHint != null) ...[
              const SizedBox(height: 4),
              Text(
                actionHint!,
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: actionEnabled ? onAction : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: card,
    );
  }
}

class _UpgradeConfirmSheet extends StatelessWidget {
  const _UpgradeConfirmSheet({
    required this.title,
    required this.subtitle,
    required this.todayLabel,
    required this.afterLabel,
    required this.todayDetail,
    required this.afterDetail,
    required this.todayPrice,
    required this.afterPrice,
    required this.continueLabel,
    required this.legal,
  });

  final String title;
  final String subtitle;
  final String todayLabel;
  final String afterLabel;
  final String todayDetail;
  final String afterDetail;
  final String todayPrice;
  final String afterPrice;
  final String continueLabel;
  final String legal;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2A1B3D), Color(0xFF14101C)],
            ),
            border: Border.all(
              color: AppTheme.muted.withValues(alpha: 0.18),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.muted.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close),
                      color: AppTheme.muted,
                    ),
                  ],
                ),
                if (subtitle.isNotEmpty) ...[
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else
                  const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.white.withValues(alpha: 0.04),
                    border: Border.all(
                      color: AppTheme.muted.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Column(
                    children: [
                      _UpgradeCompareRow(
                        label: todayLabel,
                        detail: todayDetail,
                        price: todayPrice,
                        emphasize: false,
                      ),
                      Divider(
                        height: 1,
                        color: AppTheme.muted.withValues(alpha: 0.16),
                      ),
                      _UpgradeCompareRow(
                        label: afterLabel,
                        detail: afterDetail,
                        price: afterPrice,
                        emphasize: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: AppTheme.ink,
                    foregroundColor: AppTheme.background,
                  ),
                  child: Text(
                    continueLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  legal,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.muted.withValues(alpha: 0.9),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpgradeCompareRow extends StatelessWidget {
  const _UpgradeCompareRow({
    required this.label,
    required this.detail,
    required this.price,
    required this.emphasize,
  });

  final String label;
  final String detail;
  final String price;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            price,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: emphasize ? AppTheme.accentCyan : AppTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCompareTable extends StatelessWidget {
  const _PlanCompareTable({
    required this.tiers,
    required this.labelFor,
    required this.creditsFor,
    required this.featurePlusEffects,
    required this.featureProEffects,
    required this.featureAi,
    required this.featureCredits,
    required this.featureStudioExtras,
    required this.title,
  });

  final List<PlanTier> tiers;
  final String Function(PlanTier tier) labelFor;
  final int Function(PlanTier tier) creditsFor;
  final String featurePlusEffects;
  final String featureProEffects;
  final String featureAi;
  final String featureCredits;
  final String featureStudioExtras;
  final String title;

  bool _hasPlus(PlanTier tier) =>
      tier == PlanTier.plus ||
      tier == PlanTier.pro ||
      tier == PlanTier.studio;

  bool _hasPro(PlanTier tier) =>
      tier == PlanTier.pro || tier == PlanTier.studio;

  bool _hasAi(PlanTier tier) =>
      tier == PlanTier.pro || tier == PlanTier.studio;

  bool _hasStudio(PlanTier tier) => tier == PlanTier.studio;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2A1B3D), Color(0xFF171022)],
        ),
        border: Border.all(
          color: AppTheme.muted.withValues(alpha: 0.14),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 12),
            _CompareHeader(
              labels: [for (final tier in tiers) labelFor(tier)],
            ),
            const SizedBox(height: 6),
            _CompareBoolRow(
              label: featurePlusEffects,
              values: [for (final tier in tiers) _hasPlus(tier)],
            ),
            _CompareBoolRow(
              label: featureProEffects,
              values: [for (final tier in tiers) _hasPro(tier)],
            ),
            _CompareBoolRow(
              label: featureAi,
              values: [for (final tier in tiers) _hasAi(tier)],
            ),
            _CompareTextRow(
              label: featureCredits,
              values: [
                for (final tier in tiers) '${creditsFor(tier)}',
              ],
            ),
            _CompareBoolRow(
              label: featureStudioExtras,
              values: [for (final tier in tiers) _hasStudio(tier)],
              showDivider: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompareHeader extends StatelessWidget {
  const _CompareHeader({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(flex: 5, child: SizedBox.shrink()),
        for (final label in labels)
          Expanded(
            flex: 2,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: AppTheme.ink,
              ),
            ),
          ),
      ],
    );
  }
}

class _CompareBoolRow extends StatelessWidget {
  const _CompareBoolRow({
    required this.label,
    required this.values,
    this.showDivider = true,
  });

  final String label;
  final List<bool> values;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
              for (final ok in values)
                Expanded(
                  flex: 2,
                  child: Icon(
                    ok ? Icons.check : Icons.remove,
                    size: 18,
                    color: ok ? AppTheme.accent : AppTheme.muted,
                  ),
                ),
            ],
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: AppTheme.muted.withValues(alpha: 0.16),
          ),
      ],
    );
  }
}

class _CompareTextRow extends StatelessWidget {
  const _CompareTextRow({
    required this.label,
    required this.values,
  });

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
              for (final value in values)
                Expanded(
                  flex: 2,
                  child: Text(
                    value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: AppTheme.ink,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Divider(
          height: 1,
          color: AppTheme.muted.withValues(alpha: 0.16),
        ),
      ],
    );
  }
}

/// Debug-only chips: free / Plus·Pro × monthly·yearly.
class _DebugPlanPresets extends StatelessWidget {
  const _DebugPlanPresets({
    required this.selected,
    required this.onSelect,
  });

  final ({PlanTier tier, bool annual})? selected;
  final void Function(PlanTier? tier, bool annual) onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = <(PlanTier?, bool, String)>[
      (null, false, 'Off'),
      (PlanTier.plus, false, '${l10n.planPlusLabel} · ${l10n.planBillingMonthly}'),
      (PlanTier.plus, true, '${l10n.planPlusLabel} · ${l10n.planBillingAnnual}'),
      (PlanTier.pro, false, '${l10n.planProLabel} · ${l10n.planBillingMonthly}'),
      (PlanTier.pro, true, '${l10n.planProLabel} · ${l10n.planBillingAnnual}'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (tier, annual, label) in options)
          _DebugPresetChip(
            label: label,
            selected: tier == null
                ? selected == null
                : selected?.tier == tier && selected?.annual == annual,
            onTap: () => onSelect(tier, annual),
          ),
      ],
    );
  }
}

class _DebugPresetChip extends StatelessWidget {
  const _DebugPresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: selected
                  ? AppTheme.accent
                  : AppTheme.muted.withValues(alpha: 0.28),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? AppTheme.ink : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}
