import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Pro paywall. Pops `true` when Pro is active on exit.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key, this.pro, this.source = 'settings'});

  /// Override for tests; defaults to [ProService.instance].
  final ProService? pro;

  /// Where the paywall was opened from (analytics only).
  final String source;

  static Future<bool> open(
    BuildContext context, {
    String source = 'settings',
  }) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallScreen(source: source),
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
    final plans = await _pro.loadPlans();
    if (!mounted) return;
    setState(() {
      _plans = plans;
      _selected = plans.isEmpty ? null : plans.first;
      _loading = false;
    });
  }

  void _close() => Navigator.of(context).pop(_pro.isPro);

  Future<void> _subscribe() async {
    final plan = _selected;
    if (plan == null || _busy) return;
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
        });
        _close();
      case ProPurchaseResult.cancelled:
        analytics.log('purchase_cancelled', {'plan': plan.id});
      case ProPurchaseResult.failed:
      case ProPurchaseResult.unavailable:
        analytics.log('purchase_failed', {'plan': plan.id});
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
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
              Text(
                l10n.proTitle(l10n.appTitle),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.proSubtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(height: 24),
              for (final benefit in [
                l10n.proBenefitEffects,
                l10n.proBenefitNoAds,
                l10n.proBenefitFuture,
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: AppTheme.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text(benefit)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (_pro.isPro)
                _StatusCard(text: l10n.proActive)
              else if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_plans.isEmpty)
                _StatusCard(text: l10n.proStoreUnavailable)
              else ...[
                for (final plan in _plans)
                  _PlanTile(
                    plan: plan,
                    selected: plan == _selected,
                    badge: plan.isAnnual ? l10n.proAnnualBadge : null,
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
                      : Text(l10n.proSubscribe),
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
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? AppTheme.accent : AppTheme.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    plan.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (badge != null) ...[
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
                  const SizedBox(width: 10),
                ],
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
