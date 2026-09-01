import 'package:aveditor/models/export_quality_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists app-wide preferences such as the default export quality.
class AppSettingsService {
  const AppSettingsService();

  static const _exportQualityKey = 'export_quality_profile';

  Future<ExportQualityProfile> getExportQualityProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_exportQualityKey);
    if (stored == null) {
      return ExportQualityProfile.recommended;
    }
    return ExportQualityProfile.values.byName(stored);
  }

  Future<void> setExportQualityProfile(ExportQualityProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_exportQualityKey, profile.name);
  }
}
