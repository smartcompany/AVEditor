/// Wraps a value as a single-quoted shell argument.
String quoteShell(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

String formatFfmpegSeconds(Duration duration) {
  return (duration.inMilliseconds / 1000.0).toStringAsFixed(3);
}
