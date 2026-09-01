import 'package:aveditor/config/music_api_config.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/services/app_settings_service.dart';
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.exportQualitySection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ...ExportQualityProfile.values.map(
                  (profile) => _QualityTile(
                    profile: profile,
                    groupValue: _selected,
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
                    leading: Icon(
                      MusicApiConfig.hasJamendoCatalog
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                    ),
                    title: Text(
                      MusicApiConfig.hasJamendoCatalog
                          ? 'Jamendo'
                          : l10n.musicCatalogUnavailable,
                    ),
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
    required this.profile,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final ExportQualityProfile profile;
  final ExportQualityProfile? groupValue;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: RadioListTile<ExportQualityProfile>(
        value: profile,
        groupValue: groupValue,
        onChanged: (_) => onTap(),
        title: Text(title),
        subtitle: Text(subtitle),
        controlAffinity: ListTileControlAffinity.trailing,
      ),
    );
  }
}
