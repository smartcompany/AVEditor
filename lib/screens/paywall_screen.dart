import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/theme/app_theme.dart';
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
    this.preferAnnual = true,
  });

  final ProService? pro;
  final String source;
  /// Initial billing period tab. Falls back if that period has no plans.
  final bool preferAnnual;

  static Future<bool> open(
    BuildContext context, {
    String source = 'settings',
    bool preferAnnual = true,
  }) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallScreen(
          source: source,
          preferAnnual: preferAnnual,
        ),
      ),
    );
    return result ?? ProService.instance.isPro;
  }

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

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
    _load();
  }

  @override
  void dispose() {
    _pro.removeListener(_onProChanged);
    super.dispose();
  }

  void _onProChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await _pro.ensureInitialized();
    await CreditService.instance.ensureInitialized();
    await CreditService.instance.ensurePlansLoaded();
    final plans = _filterEnabledPlans(await _pro.loadPlans());
    if (!mounted) return;
    final hasAnnual = plans.any((p) => p.isAnnual);
    final hasMonthly = plans.any((p) => !p.isAnnual);
    final preferAnnual = widget.preferAnnual;
    final useAnnual = preferAnnual
        ? (hasAnnual || !hasMonthly)
        : (hasMonthly ? false : hasAnnual);
    setState(() {
      _plans = plans;
      _annual = useAnnual;
      _selected = _pickDefault(plans, annual: _annual);
      _loading = false;
    });
    AnalyticsService.instance.log('paywall_catalog', {
      'source': widget.source,
      'count': plans.length,
      'store_available': _pro.storeAvailable,
      if (_pro.lastCatalogError != null) 'catalog_error': _pro.lastCatalogError,
    });
  }

  /// Hide paid tiers the dashboard marked as disabled.
  List<ProPlan> _filterEnabledPlans(List<ProPlan> plans) {
    final credits = CreditService.instance;
    final remote = credits.plans;
    // No remote catalog yet → show store/debug plans as-is.
    if (remote.isEmpty) return plans;
    return [
      for (final plan in plans)
        if (plan.tier == PlanTier.free ||
            (credits.planById(_tierId(plan.tier))?.enabled ?? false))
          plan,
    ];
  }

  ProPlan? _pickDefault(List<ProPlan> plans, {required bool annual}) {
    final filtered = plans.where((p) => p.isAnnual == annual).toList();
    if (filtered.isEmpty) return plans.isEmpty ? null : plans.first;
    // Prefer the highest enabled paid tier as the default highlight.
    for (final tier in [PlanTier.studio, PlanTier.pro, PlanTier.plus]) {
      for (final p in filtered) {
        if (p.tier == tier) return p;
      }
    }
    return filtered.first;
  }

  List<ProPlan> get _visiblePlans {
    final filtered = _plans.where((p) => p.isAnnual == _annual).toList();
    if (filtered.isNotEmpty) return filtered;
    return _plans;
  }

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

  Future<void> _subscribe() async {
    final plan = _selected;
    if (plan == null || _busy) return;

    // Store billing uses the phone's Apple / Google account — no app login.
    setState(() => _busy = true);
    final result = await _pro.purchase(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    final analytics = AnalyticsService.instance;
    switch (result) {
      case ProPurchaseResult.purchased:
        analytics.log('purchase_success', {
          'plan': plan.id,
          'annual': plan.isAnnual,
          'tier': plan.tier.name,
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
    if (_busy) return;
    setState(() => _busy = true);
    final active = await _pro.restore();
    if (!mounted) return;
    setState(() => _busy = false);
    if (active) {
      AnalyticsService.instance.log('restore_success');
      _close();
    } else {
      _snack(context.l10n.proRestoreNone);
    }
  }

  void _snack(String message) {
    showLoggedSnackBar(context, message);
  }

  PlanTier get _focusTier => _selected?.tier ?? PlanTier.pro;

  String _lang(BuildContext context) =>
      Localizations.localeOf(context).languageCode;

  String _tierId(PlanTier tier) => switch (tier) {
        PlanTier.plus => 'plus',
        PlanTier.studio => 'studio',
        PlanTier.pro || PlanTier.free => 'pro',
      };

  int _monthlyCredits(PlanTier tier) =>
      CreditService.instance.monthlyCreditsFor(_tierId(tier));

  String _titleFor(BuildContext context, AppLocalizations l10n, PlanTier tier) {
    final remote = CreditService.instance.planById(_tierId(tier));
    final app = l10n.appTitle;
    if (remote != null) {
      final name = remote.localizedTitle(_lang(context));
      if (name.isNotEmpty) return '$app $name';
    }
    return switch (tier) {
      PlanTier.plus => l10n.planPlusTitle(app),
      PlanTier.studio => l10n.planStudioTitle(app),
      PlanTier.pro || PlanTier.free => l10n.planProTitle(app),
    };
  }

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
    return l10n.planActive(_tierLabel(context, l10n, _pro.tier));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tier = _focusTier;
    final benefits = _benefitsFor(context, l10n, tier);
    final visible = _visiblePlans;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), onPressed: _close),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: AppTheme.brandGradientDecoration(
                    borderRadius: 20,
                  ),
                  child: const Icon(
                    Icons.workspace_premium,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Column(
                  key: ValueKey(tier),
                  children: [
                    Text(
                      _titleFor(context, l10n, tier),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _subtitleFor(context, l10n, tier),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    for (final benefit in benefits)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: AppTheme.accent,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(benefit)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_pro.isPro && _plans.isEmpty)
                _StatusCard(text: _activeStatusText(context, l10n))
              else if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_plans.isEmpty) ...[
                _StatusCard(text: l10n.proStoreUnavailable),
                if (kDebugMode && (_pro.lastCatalogError?.isNotEmpty ?? false))
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
                    child: _StatusCard(text: _activeStatusText(context, l10n)),
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
                    badge: plan.isAnnual
                        ? l10n.proAnnualBadge
                        : _tierLabel(context, l10n, plan.tier),
                    onTap: () => setState(() => _selected = plan),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy || _selected == null ? null : _subscribe,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          l10n.planSubscribeCta(
                            _tierLabel(
                              context,
                              l10n,
                              _selected?.tier ?? PlanTier.pro,
                            ),
                          ),
                        ),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _restore,
                child: Text(l10n.proRestore),
              ),
              if (kDebugMode)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.proDebugToggle),
                  value: _pro.debugProEnabled,
                  onChanged: (v) => _pro.setDebugPro(v),
                ),
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
        if (annual) ...[
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
    required this.onTap,
    this.badge,
  });

  final ProPlan plan;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? AppTheme.accent : Colors.white12,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected ? AppTheme.accent : AppTheme.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    plan.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.circular(6),
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
                ],
                const SizedBox(width: 10),
                Text(
                  plan.price,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
