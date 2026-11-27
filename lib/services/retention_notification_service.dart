import 'dart:async';
import 'dart:io';

import 'package:aveditor/models/push_notification_category.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Local retention pushes for CapCut-style loops (no FCM server required):
/// 1. Draft abandon (24h / 72h)
/// 2. Post-export share nudge (~4h)
/// 3. Catalog drop when transition/text pack version increases
class RetentionNotificationService {
  RetentionNotificationService._();

  static final RetentionNotificationService instance =
      RetentionNotificationService._();

  static const _channelId = 'easyclip_retention';
  static const _channelName = 'EasyClip reminders';

  static const idDraft24 = 1001;
  static const idDraft72 = 1002;
  static const idShareNudge = 2001;
  static const idCatalogDrop = 3001;

  static const _prefsDraftProject = 'retention_draft_project_id';
  static const _prefsPendingDraft = 'retention_pending_draft_project_id';
  static const _prefsShareProject = 'retention_share_project_id';
  static const _prefsTransitionVer = 'retention_notified_transition_ver';
  static const _prefsTextVer = 'retention_notified_text_ver';
  static const _prefsCatalogSeeded = 'retention_catalog_seeded';

  /// Delay before the first draft reminder.
  static const draftDelay = Duration(hours: 24);

  /// Second draft reminder if still unfinished.
  static const draftFollowUpDelay = Duration(hours: 72);

  /// Share nudge after a successful export with no share tap.
  static const shareNudgeDelay = Duration(hours: 4);

  final _plugin = FlutterLocalNotificationsPlugin();
  final _settings = const AppSettingsService();
  var _ready = false;
  void Function(String payload)? onNotificationTap;

  /// Payload waiting when the app was cold-started from a notification.
  String? launchPayload;

  Future<void> ensureInitialized() async {
    if (_ready || kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) {
      _ready = true;
      return;
    }

    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.local);
    } catch (_) {
      // Device timezone name may be missing in some sandboxes.
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: iosInit,
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      launchPayload = launch!.notificationResponse?.payload;
    }

    _ready = true;
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    AnalyticsService.instance.log('retention_push_tap', {'payload': payload});
    onNotificationTap?.call(payload);
  }

  Future<bool> _softPromptSeen() => _settings.hasSeenNotificationPrefPrompt();

  Future<bool> requestPermissionIfNeeded() async {
    // Soft pref popup on Home must run before the OS dialog.
    if (!await _softPromptSeen()) return false;
    if (!_ready) await ensureInitialized();
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? false;
    }
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final granted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }
    return false;
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Reminders to finish and share clips',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  Future<void> _schedule({
    required int id,
    required Duration delay,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_ready) await ensureInitialized();
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;
    final when = tz.TZDateTime.now(tz.local).add(delay);
    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: when,
        notificationDetails: _details,
        title: title,
        body: body,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e, st) {
      debugPrint('[RetentionPush] schedule $id failed: $e\n$st');
    }
  }

  Future<void> cancel(int id) => _plugin.cancel(id: id);

  Future<bool> _categoryAllowed(PushNotificationCategory category) {
    return _settings.isNotificationCategoryEnabled(category);
  }

  /// Cancel pending notifications after a Settings preference change.
  ///
  /// Pass [category] to cancel one kind, or omit to cancel everything
  /// (master off).
  Future<void> applyPreferenceChange({
    PushNotificationCategory? category,
  }) async {
    if (!_ready) await ensureInitialized();
    if (category == null) {
      await cancelDraftAbandon();
      await cancelShareNudge();
      await cancel(idCatalogDrop);
      return;
    }
    switch (category) {
      case PushNotificationCategory.draft:
        await cancelDraftAbandon();
      case PushNotificationCategory.share:
        await cancelShareNudge();
      case PushNotificationCategory.catalog:
        await cancel(idCatalogDrop);
    }
  }

  /// Priority 1 — leaving the editor with an unfinished draft.
  Future<void> scheduleDraftAbandon({
    required String projectId,
    required String title,
    required String body24,
    required String body72,
  }) async {
    if (!await _categoryAllowed(PushNotificationCategory.draft)) {
      await cancelDraftAbandon();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsPendingDraft);
      return;
    }
    // Soft pref popup hasn't been shown yet — stash and let Home prompt first.
    if (!await _softPromptSeen()) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsPendingDraft, projectId);
      return;
    }
    await _scheduleDraftAbandonNow(
      projectId: projectId,
      title: title,
      body24: body24,
      body72: body72,
    );
  }

  /// After the Home soft-pref popup, schedule any draft left while prompting.
  Future<void> flushPendingDraftAbandon({
    required String title,
    required String body24,
    required String body72,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final projectId = prefs.getString(_prefsPendingDraft);
    if (projectId == null || projectId.isEmpty) return;
    await prefs.remove(_prefsPendingDraft);
    await scheduleDraftAbandon(
      projectId: projectId,
      title: title,
      body24: body24,
      body72: body72,
    );
  }

  Future<void> _scheduleDraftAbandonNow({
    required String projectId,
    required String title,
    required String body24,
    required String body72,
  }) async {
    await requestPermissionIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsDraftProject, projectId);
    await cancel(idDraft24);
    await cancel(idDraft72);
    final payload = 'draft:$projectId';
    await _schedule(
      id: idDraft24,
      delay: draftDelay,
      title: title,
      body: body24,
      payload: payload,
    );
    await _schedule(
      id: idDraft72,
      delay: draftFollowUpDelay,
      title: title,
      body: body72,
      payload: payload,
    );
    AnalyticsService.instance.log('retention_draft_scheduled');
  }

  Future<void> cancelDraftAbandon() async {
    await cancel(idDraft24);
    await cancel(idDraft72);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsDraftProject);
  }

  /// Priority 2 — export finished but user has not shared yet.
  Future<void> scheduleShareNudge({
    required String projectId,
    required String title,
    required String body,
  }) async {
    if (!await _categoryAllowed(PushNotificationCategory.share)) {
      await cancelShareNudge();
      return;
    }
    await requestPermissionIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsShareProject, projectId);
    await cancel(idShareNudge);
    await _schedule(
      id: idShareNudge,
      delay: shareNudgeDelay,
      title: title,
      body: body,
      payload: 'share:$projectId',
    );
    AnalyticsService.instance.log('retention_share_scheduled');
  }

  Future<void> cancelShareNudge() async {
    await cancel(idShareNudge);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsShareProject);
  }

  /// Priority 3 — new catalog assets after first seed.
  Future<void> onCatalogVersions({
    required int transitionVersion,
    required int textPackVersion,
    required String title,
    required String body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final seeded = prefs.getBool(_prefsCatalogSeeded) ?? false;
    if (!seeded) {
      await prefs.setBool(_prefsCatalogSeeded, true);
      await prefs.setInt(_prefsTransitionVer, transitionVersion);
      await prefs.setInt(_prefsTextVer, textPackVersion);
      return;
    }

    final lastT = prefs.getInt(_prefsTransitionVer) ?? 0;
    final lastP = prefs.getInt(_prefsTextVer) ?? 0;
    final newer =
        transitionVersion > lastT || textPackVersion > lastP;
    if (!newer) return;

    await prefs.setInt(_prefsTransitionVer, transitionVersion);
    await prefs.setInt(_prefsTextVer, textPackVersion);

    if (!await _categoryAllowed(PushNotificationCategory.catalog)) {
      await cancel(idCatalogDrop);
      return;
    }

    await requestPermissionIfNeeded();
    await cancel(idCatalogDrop);
    // Slight delay so the user is not interrupted mid-session on cold start.
    await _schedule(
      id: idCatalogDrop,
      delay: const Duration(minutes: 30),
      title: title,
      body: body,
      payload: 'catalog',
    );
    AnalyticsService.instance.log('retention_catalog_scheduled', {
      'transition': transitionVersion,
      'text': textPackVersion,
    });
  }

  static String? projectIdFromPayload(String payload) {
    if (payload.startsWith('draft:')) {
      return payload.substring('draft:'.length);
    }
    if (payload.startsWith('share:')) {
      return payload.substring('share:'.length);
    }
    return null;
  }
}
