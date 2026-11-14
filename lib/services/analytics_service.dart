import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Anonymous usage events for the dashboard (install → editing → export →
/// Pro / ads). Identifies a device only by a random install id; no account,
/// file names or text content are sent.
///
/// Events are queued, persisted, and posted in batches to `/api/events`, so
/// offline sessions are delivered later and tracking never blocks the UI.
class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  static const endpoint = 'https://aveditorserver.vercel.app/api/events';
  static const _installIdKey = 'analytics_install_id';
  static const _queueKey = 'analytics_queue';
  static const _maxQueued = 500;
  static const _batchSize = 50;
  static const _flushDelay = Duration(seconds: 8);

  /// Tests and debug sessions can turn sending off.
  bool enabled = !kDebugMode || const bool.fromEnvironment('ANALYTICS_DEBUG');

  String? _installId;
  String _platform = 'unknown';
  String _appVersion = '';
  final List<Map<String, Object?>> _queue = [];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _initialized = false;

  /// Loads the install id and queued events, then logs app start.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_installIdKey);
    final firstRun = id == null;
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_installIdKey, id);
    }
    _installId = id;
    if (!kIsWeb) {
      _platform = Platform.isIOS
          ? 'ios'
          : Platform.isAndroid
          ? 'android'
          : Platform.operatingSystem;
    }
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    final stored = prefs.getString(_queueKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as List<dynamic>;
        _queue.addAll(decoded.cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    if (firstRun) log('first_open');
    log('app_open');
  }

  /// Queues [event] with small, non-personal [props].
  void log(String event, [Map<String, Object?> props = const {}]) {
    // Off in debug builds and tests unless --dart-define=ANALYTICS_DEBUG=true,
    // so development sessions do not pollute the dashboard.
    if (!enabled) return;
    _queue.add({
      'event': event,
      if (props.isNotEmpty) 'props': props,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    if (_queue.length > _maxQueued) {
      _queue.removeRange(0, _queue.length - _maxQueued);
    }
    unawaited(_persist());
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Sends queued events now (also called when the app goes to background).
  Future<void> flush() async {
    if (!enabled || _flushing || _queue.isEmpty || _installId == null) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(_batchSize).toList();
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'install_id': _installId,
                'platform': _platform,
                'app_version': _appVersion,
                'events': batch,
              }),
            )
            .timeout(const Duration(seconds: 10));
        // 4xx means the batch itself is bad; drop it rather than retry forever.
        if (response.statusCode >= 500) break;
        _queue.removeRange(0, batch.length);
        await _persist();
      }
    } catch (e) {
      debugPrint('[analytics] flush failed, will retry: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueKey, jsonEncode(_queue));
    } catch (_) {}
  }
}
