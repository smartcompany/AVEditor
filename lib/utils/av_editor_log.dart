import 'package:flutter/foundation.dart';

/// Prints [message] plus the caller frame so the debug console can open it.
void avEditorLog(String message) {
  debugPrint('AVEditor $message ${_callerLink(StackTrace.current)}');
}

String _callerLink(StackTrace stack) {
  for (final line in stack.toString().split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.contains('avEditorLog') || trimmed.contains('_callerLink')) {
      continue;
    }
    return trimmed;
  }
  return '';
}
