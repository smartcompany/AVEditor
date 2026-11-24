import 'dart:math' as math;

import 'package:aveditor/utils/duration_format.dart';

/// Default timeline / export frame rate until projects carry an explicit fps.
const timelineRulerFps = 30;

/// CapCut-like adaptive marks: seconds when zoomed out, `Nf` when zoomed in.
enum TimelineRulerMarkKind { second, frame, minor }

class TimelineRulerMark {
  const TimelineRulerMark({
    required this.time,
    required this.kind,
    required this.label,
  });

  final Duration time;
  final TimelineRulerMarkKind kind;

  /// Empty for [TimelineRulerMarkKind.minor] (dot only).
  final String label;
}

/// Builds ruler marks for the visible range given [pxPerSecond].
///
/// - Always prefers whole-second labels when they fit.
/// - When ~10-frame steps have enough pixel room, inserts `10f` / `20f` …
///   between seconds (30fps → 10f, 20f before the next second).
/// - Otherwise inserts mid-second dots when space allows.
List<TimelineRulerMark> buildTimelineRulerMarks({
  required Duration rangeStart,
  required Duration rangeEnd,
  required double pxPerSecond,
  int fps = timelineRulerFps,
  double minLabelSpacingPx = 36,
  double minMinorSpacingPx = 14,
}) {
  if (rangeEnd <= rangeStart || pxPerSecond <= 0 || fps <= 0) {
    return const [];
  }

  final safeFps = fps.clamp(1, 240);
  final pxPerFrame = pxPerSecond / safeFps;
  final startMs = math.max(0, rangeStart.inMilliseconds);
  final endMs = rangeEnd.inMilliseconds;

  // Largest second step whose labels stay ≥ minLabelSpacingPx apart.
  const secondSteps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
  var majorSeconds = secondSteps.last;
  for (final step in secondSteps) {
    if (step * pxPerSecond >= minLabelSpacingPx) {
      majorSeconds = step;
      break;
    }
  }

  // Frame subdivisions inside each second (CapCut prefers 10f / 20f at 30fps).
  int? frameStep;
  for (final s in const [10, 5, 2, 1, 15]) {
    if (s < safeFps && s * pxPerFrame >= minLabelSpacingPx) {
      frameStep = s;
      break;
    }
  }

  final showMidDot = frameStep == null &&
      majorSeconds == 1 &&
      (pxPerSecond / 2) >= minMinorSpacingPx;

  final marks = <TimelineRulerMark>[];
  final firstSec = startMs ~/ 1000;
  final lastSec = (endMs / 1000).ceil() + majorSeconds;

  for (var sec = firstSec; sec <= lastSec; sec++) {
    if (sec < 0) continue;
    if (sec % majorSeconds != 0) continue;
    final t = Duration(seconds: sec);
    if (t < rangeStart - const Duration(milliseconds: 50) ||
        t > rangeEnd + const Duration(milliseconds: 50)) {
      continue;
    }
    marks.add(
      TimelineRulerMark(
        time: t,
        kind: TimelineRulerMarkKind.second,
        label: formatTimelineClock(
          t,
          useHours: t.inHours > 0 || rangeEnd.inHours > 0,
        ),
      ),
    );

    if (frameStep != null && majorSeconds == 1) {
      for (var f = frameStep; f < safeFps; f += frameStep) {
        final ft = Duration(
          milliseconds: sec * 1000 + ((f * 1000) / safeFps).round(),
        );
        if (ft < rangeStart || ft > rangeEnd) continue;
        marks.add(
          TimelineRulerMark(
            time: ft,
            kind: TimelineRulerMarkKind.frame,
            label: '${f}f',
          ),
        );
      }
    } else if (showMidDot) {
      final mid = Duration(milliseconds: sec * 1000 + 500);
      if (mid >= rangeStart && mid <= rangeEnd) {
        marks.add(
          TimelineRulerMark(
            time: mid,
            kind: TimelineRulerMarkKind.minor,
            label: '',
          ),
        );
      }
    }
  }

  marks.sort((a, b) => a.time.compareTo(b.time));
  return marks;
}
