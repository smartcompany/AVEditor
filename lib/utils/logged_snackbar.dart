import 'package:aveditor/utils/av_editor_log.dart';
import 'package:flutter/material.dart';

/// Shows a [SnackBar] and always mirrors the same text to the debug console
/// so failures are easy to copy from Xcode / `flutter run` logs.
void showLoggedSnackBar(
  BuildContext context,
  String message, {
  Object? error,
  StackTrace? stackTrace,
  Duration duration = const Duration(seconds: 4),
}) {
  final buf = StringBuffer('SNACK $message');
  if (error != null) {
    buf.write(' | $error');
  }
  avEditorLog(buf.toString());
  if (stackTrace != null) {
    debugPrint(stackTrace.toString());
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: duration),
  );
}
