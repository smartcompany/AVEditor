import 'package:aveditor/app_auth_provider.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/screens/paywall_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/auth_helper.dart';
import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = const AppSettingsService();
  ExportQualityProfile? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    AppAuthProvider.shared.addListener(_onAuthChanged);
    CreditService.instance.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AppAuthProvider.shared.removeListener(_onAuthChanged);
    CreditService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final profile = await _settings.getExportQualityProfile();
    if (!mounted) return;
    setState(() {
      _selected = profile;
      _loading = false;
    });
  }

  Future<void> _select(ExportQualityProfile profile) async {
    await _settings.setExportQualityProfile(profile);
    if (!mounted) return;
    setState(() => _selected = profile);
  }

  Future<void> _signIn() async {
    await AuthHelper.requireAuth(context);
  }

  Future<void> _signOut() async {
    await AppAuthProvider.shared.logout();
  }

  String _tierLabel(BuildContext context) {
    final l10n = context.l10n;
    final app = l10n.appTitle;
    return switch (ProService.instance.tier) {
      PlanTier.studio => l10n.planStudioTitle(app),
      PlanTier.pro => l10n.planProTitle(app),
      PlanTier.plus => l10n.planPlusTitle(app),
      PlanTier.free => l10n.planPlusTitle(app),
    };
  }

  String _tierSubtitle(BuildContext context) {
    final l10n = context.l10n;
    final pro = ProService.instance;
    if (pro.tier == PlanTier.free) {
      return l10n.planSubscribeCta(l10n.planPlusLabel);
    }
    final plan = switch (pro.tier) {
      PlanTier.studio => l10n.planStudioLabel,
      PlanTier.pro => l10n.planProLabel,
      PlanTier.plus => l10n.planPlusLabel,
      PlanTier.free => l10n.planPlusLabel,
    };
    final annual = pro.activeIsAnnual;
    if (annual == null) return l10n.planActive(plan);
    final period =
        annual ? l10n.planBillingAnnual : l10n.planBillingMonthly;
    return l10n.planActiveWithPeriod(plan, period);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final auth = AppAuthProvider.shared;
    final loggedIn = auth.isLoggedIn();
    final user = auth.userProfile;
    final display = user?.displayName ??
        user?.email ??
        (loggedIn ? '—' : l10n.accountSignIn);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.accountSection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          loggedIn
                              ? Icons.account_circle
                              : Icons.login,
                          color: loggedIn ? AppTheme.accent : null,
                        ),
                        title: Text(
                          loggedIn
                              ? l10n.accountSignedInAs(display)
                              : l10n.accountSignIn,
                        ),
                        subtitle: ListenableBuilder(
                          listenable: CreditService.instance,
                          builder: (context, _) {
                            final credits = CreditService.instance;
                            if (!credits.isReady) {
                              return Text(l10n.creditsBalanceLabel(0));
                            }
                            return Text(
                              l10n.creditsBalanceLabel(credits.balance),
                            );
                          },
                        ),
                        trailing: loggedIn
                            ? TextButton(
                                onPressed: _signOut,
                                child: Text(l10n.accountSignOut),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: loggedIn ? null : _signIn,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.proSection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: ProService.instance,
                  builder: (context, _) {
                    final pro = ProService.instance;
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.workspace_premium,
                          color: pro.isPro ? AppTheme.accent : null,
                        ),
                        title: Text(_tierLabel(context)),
                        subtitle: Text(_tierSubtitle(context)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => PaywallScreen.open(context),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.exportQualitySection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ...ExportQualityProfile.values.map(
                  (profile) => _QualityTile(
                    selected: _selected == profile,
                    title: _titleFor(profile, l10n),
                    subtitle: _subtitleFor(profile, l10n),
                    onTap: () => _select(profile),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.musicCatalogSection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(l10n.musicCatalogReady),
                    subtitle: Text(l10n.musicCatalogBody),
                  ),
                ),
              ],
            ),
    );
  }

  String _titleFor(ExportQualityProfile profile, dynamic l10n) {
    return switch (profile) {
      ExportQualityProfile.recommended => l10n.exportQualityRecommendedTitle,
      ExportQualityProfile.high => l10n.exportQualityHighTitle,
      ExportQualityProfile.smaller => l10n.exportQualitySmallerTitle,
      ExportQualityProfile.original => l10n.exportQualityOriginalTitle,
    };
  }

  String _subtitleFor(ExportQualityProfile profile, dynamic l10n) {
    return switch (profile) {
      ExportQualityProfile.recommended => l10n.exportQualityRecommendedBody,
      ExportQualityProfile.high => l10n.exportQualityHighBody,
      ExportQualityProfile.smaller => l10n.exportQualitySmallerBody,
      ExportQualityProfile.original => l10n.exportQualityOriginalBody,
    };
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          color: selected ? AppTheme.accent : null,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }
}
