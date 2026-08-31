import 'package:flutter/foundation.dart';

/// Debug-only overlay/editor interaction logs.
/// Filter console with: `[OverlayEvent]`
class OverlayEventLog {
  OverlayEventLog._();

  static bool enabled = kDebugMode;

  static void log(
    String scope,
    String event, [
    Map<String, Object?>? data,
  ]) {
    if (!enabled) return;
    final buffer = StringBuffer('[OverlayEvent] $scope.$event');
    if (data != null && data.isNotEmpty) {
      buffer.write(' | ');
      buffer.write(
        data.entries.map((e) => '${e.key}=${e.value}').join(' '),
      );
    }
    debugPrint(buffer.toString());
  }
}
