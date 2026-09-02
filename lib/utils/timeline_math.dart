import 'package:aveditor/utils/duration_format.dart';

const minTrimDuration = Duration(seconds: 1);
const minSplitPartDuration = Duration(milliseconds: 100);
const minOverlayDuration = Duration(milliseconds: 500);
const handleHitWidth = 18.0;

/// Minimum zoom: timeline content width = 2/3 of the viewport width.
const minTimelineZoom = 2 / 3;
const maxTimelineZoom = 24.0;

/// The playhead is pinned to the middle of the viewport and the strip scrolls
/// under it, so the content is padded by half a viewport at both ends: at time
/// zero the clip starts under the indicator rather than at the left edge.
double timelineContentInsetX(double viewportWidth) => viewportWidth / 2;

/// Scroll offset that parks [playhead] under the fixed centre indicator.
///
/// Scroll is derived from the playhead rather than tracked separately — that
/// is what keeps the indicator from drifting.
double scrollPxForPlayhead({
  required Duration playhead,
  required Duration total,
  required double contentWidth,
}) {
  return durationToContentX(playhead, total, contentWidth);
}

/// Maps absolute time → x within a zoomed content strip of [contentWidth].
double durationToContentX(Duration time, Duration total, double contentWidth) {
  final totalMs = total.inMilliseconds.clamp(1, 1 << 31);
  return (time.inMilliseconds / totalMs) * contentWidth;
}

/// Maps x on the content strip → absolute time.
Duration contentXToDuration(double x, Duration total, double contentWidth) {
  if (contentWidth <= 0) return Duration.zero;
  final ratio = (x / contentWidth).clamp(0.0, 1.0);
  return Duration(milliseconds: (total.inMilliseconds * ratio).round());
}

/// Viewport-local x (0..viewportWidth) → absolute time.
Duration viewportXToDuration({
  required double x,
  required double scrollPx,
  required Duration total,
  required double contentWidth,
  double contentInsetX = 0,
}) {
  return contentXToDuration(
    scrollPx + x - contentInsetX,
    total,
    contentWidth,
  );
}

/// Absolute time → viewport-local x.
double durationToViewportX({
  required Duration time,
  required double scrollPx,
  required Duration total,
  required double contentWidth,
  double contentInsetX = 0,
}) {
  return durationToContentX(time, total, contentWidth) -
      scrollPx +
      contentInsetX;
}

Duration snapDuration(Duration value, {int stepMs = 50}) {
  final ms = value.inMilliseconds;
  final snapped = (ms / stepMs).round() * stepMs;
  return Duration(milliseconds: snapped.clamp(0, 1 << 31));
}

bool nearX(double a, double b, {double threshold = handleHitWidth}) {
  return (a - b).abs() <= threshold;
}

String formatTimelineRange(Duration start, Duration end) {
  return '${formatDuration(start)} – ${formatDuration(end)}';
}
