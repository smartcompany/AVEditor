import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/push_notification_category.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/api_service.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

/// Registers the FCM token with the server and shows catalog pushes in-app.
class FcmPushService {
  FcmPushService._();

  static final FcmPushService instance = FcmPushService._();

  final _settings = const AppSettingsService();
  final _local = FlutterLocalNotificationsPlugin();
  var _ready = false;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _fgSub;

  Future<void> ensureInitialized() async {
    if (_ready || kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) {
      _ready = true;
      return;
    }

    try {
      // Local plugin must be ready so foreground FCM can paint a banner.
      await RetentionNotificationService.instance.ensureInitialized();

      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      if (Platform.isIOS) {
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      _fgSub ??= FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        _onOpened(initial);
      }

      _tokenSub ??= FirebaseMessaging.instance.onTokenRefresh.listen((_) {
        unawaited(syncRegistration());
      });

      await syncRegistration();
      _ready = true;
    } catch (e, st) {
      debugPrint('[FcmPush] init failed: $e\n$st');
    }
  }

  /// Refresh token + prefs on the server (call after Settings / pref sheet).
  Future<void> syncRegistration() async {
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return;
      }
      // OS prompt not shown yet — APNS/FCM won't be ready.
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
        return;
      }

      final token = await _resolveFcmToken(messaging);
      if (token == null || token.isEmpty) return;

      await AnalyticsService.instance.init();
      final deviceKey = await CreditService.instance.deviceKey();
      final master = await _settings.getNotificationMasterEnabled();
      final catalog = await _settings.getNotificationCatalogEnabled();
      final locale = _appLocale();

      await ApiService.shared.ensureAuthToken();
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        if (ApiService.shared.token != null &&
            ApiService.shared.token!.isNotEmpty)
          'Authorization': 'Bearer ${ApiService.shared.token}',
      };

      final res = await http.post(
        Uri.parse('${CreditService.baseUrl}/api/push/register'),
        headers: headers,
        body: jsonEncode({
          'deviceKey': deviceKey,
          'token': token,
          'platform': Platform.isIOS
              ? 'ios'
              : Platform.isAndroid
                  ? 'android'
                  : 'unknown',
          'locale': locale,
          'masterEnabled': master,
          'catalogEnabled': catalog,
        }),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[FcmPush] register ${res.statusCode} ${res.body}');
      }
    } catch (e, st) {
      debugPrint('[FcmPush] sync failed: $e\n$st');
    }
  }

  /// iOS needs APNS before FCM; poll briefly so cold start doesn't race.
  Future<String?> _resolveFcmToken(FirebaseMessaging messaging) async {
    if (Platform.isIOS) {
      final apns = await _waitForApnsToken(messaging);
      if (apns == null) {
        debugPrint('[FcmPush] APNS token unavailable; skip FCM register');
        return null;
      }
    }

    try {
      return await messaging.getToken();
    } catch (e) {
      final msg = e.toString();
      if (Platform.isIOS && msg.contains('apns-token-not-set')) {
        // One more short wait in case APNS landed between checks.
        final apns = await _waitForApnsToken(
          messaging,
          attempts: const [
            Duration(milliseconds: 500),
            Duration(seconds: 1),
            Duration(seconds: 2),
          ],
        );
        if (apns == null) return null;
        return messaging.getToken();
      }
      rethrow;
    }
  }

  Future<String?> _waitForApnsToken(
    FirebaseMessaging messaging, {
    List<Duration> attempts = const [
      Duration.zero,
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
    ],
  }) async {
    for (final delay in attempts) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      final token = await messaging.getAPNSToken();
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  String _appLocale() {
    final code =
        PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    if (code == 'ko' || code == 'ja' || code == 'zh' || code == 'en') {
      return code;
    }
    return 'en';
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final type = message.data['type'];
    if (type == 'catalog') {
      final allowed = await _settings.isNotificationCategoryEnabled(
        PushNotificationCategory.catalog,
      );
      if (!allowed) return;
    }

    final title = message.notification?.title ?? message.data['title'];
    final body = message.notification?.body ?? message.data['body'];
    if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
      return;
    }

    // iOS already presents via setForegroundNotificationPresentationOptions.
    if (Platform.isIOS) return;

    await _local.show(
      id: message.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'easyclip_retention',
          'EasyClip reminders',
          channelDescription: 'Reminders to finish and share clips',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: type == 'catalog' ? 'catalog' : null,
    );
  }

  void _onOpened(RemoteMessage message) {
    final type = message.data['type'];
    if (type == 'catalog') {
      AnalyticsService.instance.log('remote_push_tap', {'type': 'catalog'});
    }
  }
}
