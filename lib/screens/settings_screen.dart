import 'package:aveditor/app_auth_provider.dart';
import 'package:aveditor/l10n/app_localizations.dart';
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
      PlanTier.free => l10n.proInactive,
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
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1A0A18),
                AppTheme.background,
              ],
            ),
          ),
        ),
        title: Text(l10n.settingsTitle),
      ),
      body: DecoratedBox(
        decoration: AppTheme.ambientBackgroundDecoration(),
        child: Stack(
          children: [
            const Positioned(
              top: -40,
              left: -60,
              child: _AmbientBlob(
                diameter: 220,
                color: Color(0x38E835C1),
              ),
            ),
            const Positioned(
              top: 100,
              right: -50,
              child: _AmbientBlob(
                diameter: 200,
                color: Color(0x2E5B9DFF),
              ),
            ),
            const Positioned(
              bottom: 80,
              left: 30,
              child: _AmbientBlob(
                diameter: 180,
                color: Color(0x22FF8A3D),
              ),
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _SectionLabel(l10n.accountSection),
                  const SizedBox(height: 10),
                  _SettingsCard(
                    child: _SettingsRow(
                      leading: _LeadingGlyph(
                        icon: loggedIn
                            ? Icons.account_circle
                            : Icons.login_rounded,
                        gradient: loggedIn,
                      ),
                      title: loggedIn
                          ? l10n.accountSignedInAs(display)
                          : l10n.accountSignIn,
                      subtitle: ListenableBuilder(
                        listenable: CreditService.instance,
                        builder: (context, _) {
                          final credits = CreditService.instance;
                          final balance =
                              credits.isReady ? credits.balance : 0;
                          return Text(
                            l10n.creditsBalanceLabel(balance),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppTheme.muted),
                          );
                        },
                      ),
                      trailing: loggedIn
                          ? _SignOutCapsule(
                              label: l10n.accountSignOut,
                              onPressed: _signOut,
                            )
                          : Icon(
                              Icons.chevron_right,
                              color: AppTheme.ink.withValues(alpha: 0.7),
                            ),
                      onTap: loggedIn ? null : _signIn,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _SectionLabel(l10n.proSection),
                  const SizedBox(height: 10),
                  ListenableBuilder(
                    listenable: ProService.instance,
                    builder: (context, _) {
                      final pro = ProService.instance;
                      return _SettingsCard(
                        highlighted: pro.isPro,
                        child: _SettingsRow(
                          leading: _LeadingGlyph(
                            icon: Icons.workspace_premium,
                            gradient: true,
                          ),
                          title: _tierLabel(context),
                          subtitle: Text(
                            _tierSubtitle(context),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppTheme.muted),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: AppTheme.ink.withValues(alpha: 0.7),
                          ),
                          onTap: () => PaywallScreen.open(context),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  _SectionLabel(l10n.exportQualitySection),
                  const SizedBox(height: 10),
                  ...ExportQualityProfile.values.map(
                    (profile) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _QualityTile(
                        selected: _selected == profile,
                        title: _titleFor(profile, l10n),
                        subtitle: _subtitleFor(profile, l10n),
                        onTap: () => _select(profile),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SectionLabel(l10n.musicCatalogSection),
                  const SizedBox(height: 10),
                  _SettingsCard(
                    child: _SettingsRow(
                      leading: const _LeadingGlyph(
                        icon: Icons.library_music_outlined,
                        gradient: true,
                      ),
                      title: l10n.musicCatalogReady,
                      subtitle: Text(
                        l10n.musicCatalogBody,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppTheme.muted),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _titleFor(ExportQualityProfile profile, AppLocalizations l10n) {
    return switch (profile) {
      ExportQualityProfile.recommended => l10n.exportQualityRecommendedTitle,
      ExportQualityProfile.high => l10n.exportQualityHighTitle,
      ExportQualityProfile.smaller => l10n.exportQualitySmallerTitle,
      ExportQualityProfile.original => l10n.exportQualityOriginalTitle,
    };
  }

  String _subtitleFor(ExportQualityProfile profile, AppLocalizations l10n) {
    return switch (profile) {
      ExportQualityProfile.recommended => l10n.exportQualityRecommendedBody,
      ExportQualityProfile.high => l10n.exportQualityHighBody,
      ExportQualityProfile.smaller => l10n.exportQualitySmallerBody,
      ExportQualityProfile.original => l10n.exportQualityOriginalBody,
    };
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppTheme.muted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.child,
    this.highlighted = false,
  });

  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2A1B3D), Color(0xFF171022)],
        ),
        border: Border.all(
          color: highlighted
              ? AppTheme.accent.withValues(alpha: 0.35)
              : AppTheme.muted.withValues(alpha: 0.14),
        ),
        boxShadow: highlighted
            ? [
                BoxShadow(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
      child: child,
    );

    if (!highlighted) return card;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        gradient: AppTheme.brandGradientHorizontal,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.2),
        child: card,
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  subtitle!,
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: content,
      ),
    );
  }
}

class _LeadingGlyph extends StatelessWidget {
  const _LeadingGlyph({
    required this.icon,
    this.gradient = false,
  });

  final IconData icon;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 44,
        height: 44,
        child: DecoratedBox(
          decoration: gradient
              ? AppTheme.brandGradientDecoration(borderRadius: 12)
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(
                    color: AppTheme.muted.withValues(alpha: 0.2),
                  ),
                ),
          child: Icon(icon, color: Colors.white.withValues(alpha: 0.95)),
        ),
      ),
    );
  }
}

class _SignOutCapsule extends StatelessWidget {
  const _SignOutCapsule({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppTheme.muted.withValues(alpha: 0.35),
            ),
            color: Colors.white.withValues(alpha: 0.04),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: AppTheme.ink.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
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
    final inner = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2A1B3D), Color(0xFF171022)],
            ),
            border: selected
                ? null
                : Border.all(
                    color: AppTheme.muted.withValues(alpha: 0.14),
                  ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.16),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: selected
                      ? ShaderMask(
                          shaderCallback: (bounds) =>
                              AppTheme.brandGradientHorizontal
                                  .createShader(bounds),
                          child: const Icon(
                            Icons.check_circle,
                            color: Colors.white,
                            size: 22,
                          ),
                        )
                      : Icon(
                          Icons.circle_outlined,
                          color: AppTheme.muted.withValues(alpha: 0.7),
                          size: 22,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.muted,
                              height: 1.35,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!selected) return inner;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        gradient: AppTheme.brandGradientHorizontal,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.4),
        child: inner,
      ),
    );
  }
}

class _AmbientBlob extends StatelessWidget {
  const _AmbientBlob({
    required this.diameter,
    required this.color,
  });

  final double diameter;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
