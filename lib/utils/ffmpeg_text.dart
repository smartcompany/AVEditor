import 'package:flutter/material.dart';

/// Escapes values used in FFmpeg drawtext filter arguments.
String escapeDrawText(String text) {
  return text
      .replaceAll('\\', '\\\\')
      .replaceAll(':', '\\:')
      .replaceAll("'", "'\\''")
      .replaceAll('%', '\\%');
}

String escapeFfmpegPath(String path) {
  return path.replaceAll('\\', '/').replaceAll("'", "'\\''");
}

String quoteShell(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

String colorToFfmpeg(Color color) {
  final r = (color.r * 255.0).round().clamp(0, 255);
  final g = (color.g * 255.0).round().clamp(0, 255);
  final b = (color.b * 255.0).round().clamp(0, 255);
  return '0x${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

String formatFfmpegSeconds(Duration duration) {
  return (duration.inMilliseconds / 1000.0).toStringAsFixed(3);
}
