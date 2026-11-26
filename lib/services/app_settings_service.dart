import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/push_notification_category.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists app-wide preferences such as the default export quality.
class AppSettingsService {
  const AppSettingsService();

  static const _exportQualityKey = 'export_quality_profile';
  static const _editorOnboardingKey = 'editor_onboarding_seen_v1';
  static const _splitTransitionTipKey = 'editor_split_transition_tip_seen_v1';
  static const _splitReorderTipKey = 'editor_split_reorder_tip_seen_v1';
  /// v2 includes Text / Text Template panel tips after the corner knobs.
  static const _textChromeTipKey = 'editor_text_chrome_tip_seen_v2';

  static const _notificationMasterKey = 'notification_master_enabled_v1';
  static const _notificationDraftKey = 'notification_draft_enabled_v1';
  static const _notificationShareKey = 'notification_share_enabled_v1';
  static const _notificationCatalogKey = 'notification_catalog_enabled_v1';
  static const _notificationPrefPromptKey = 'notification_pref_prompt_seen_v1';

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

  /// First-run editor coach marks. Once true, never show again.
  Future<bool> hasSeenEditorOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_editorOnboardingKey) ?? false;
  }

  Future<void> setSeenEditorOnboarding([bool seen = true]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_editorOnboardingKey, seen);
  }

  /// Tip when the first cut marker appears: tap to add a transition.
  Future<bool> hasSeenSplitTransitionTip() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_splitTransitionTipKey) ?? false;
  }

  Future<void> setSeenSplitTransitionTip([bool seen = true]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_splitTransitionTipKey, seen);
  }

  /// Tip after the first successful video split: long-press to reorder.
  Future<bool> hasSeenSplitReorderTip() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_splitReorderTipKey) ?? false;
  }

  Future<void> setSeenSplitReorderTip([bool seen = true]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_splitReorderTipKey, seen);
  }

  /// Tip for the four corner knobs after the first text overlay is added.
  Future<bool> hasSeenTextChromeTip() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_textChromeTipKey) ?? false;
  }

  Future<void> setSeenTextChromeTip([bool seen = true]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_textChromeTipKey, seen);
  }

  /// Master switch for all local retention pushes. Default on.
  Future<bool> getNotificationMasterEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_notificationMasterKey) ?? true;
  }

  Future<void> setNotificationMasterEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationMasterKey, enabled);
  }

  /// Draft abandon reminders. Default on.
  Future<bool> getNotificationDraftEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_notificationDraftKey) ?? true;
  }

  Future<void> setNotificationDraftEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationDraftKey, enabled);
  }

  /// Post-export share nudge. Default on.
  Future<bool> getNotificationShareEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_notificationShareKey) ?? true;
  }

  Future<void> setNotificationShareEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationShareKey, enabled);
  }

  /// New catalog content (local + remote admin campaigns). Default on.
  Future<bool> getNotificationCatalogEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_notificationCatalogKey) ?? true;
  }

  Future<void> setNotificationCatalogEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationCatalogKey, enabled);
  }

  /// True when master + [category] are both enabled.
  Future<bool> isNotificationCategoryEnabled(
    PushNotificationCategory category,
  ) async {
    if (!await getNotificationMasterEnabled()) return false;
    return switch (category) {
      PushNotificationCategory.draft => getNotificationDraftEnabled(),
      PushNotificationCategory.share => getNotificationShareEnabled(),
      PushNotificationCategory.catalog => getNotificationCatalogEnabled(),
    };
  }

  /// Soft pre-permission sheet shown once before the OS dialog.
  Future<bool> hasSeenNotificationPrefPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_notificationPrefPromptKey) ?? false;
  }

  Future<void> setSeenNotificationPrefPrompt([bool seen = true]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationPrefPromptKey, seen);
  }

  /// Persist category prefs from the pre-permission sheet or Settings.
  Future<void> setNotificationPreferences({
    required bool master,
    required bool draft,
    required bool share,
    required bool catalog,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationMasterKey, master);
    await prefs.setBool(_notificationDraftKey, draft);
    await prefs.setBool(_notificationShareKey, share);
    await prefs.setBool(_notificationCatalogKey, catalog);
  }
}
