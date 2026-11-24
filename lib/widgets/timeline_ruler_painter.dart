import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/utils/timeline_ruler.dart';
import 'package:flutter/material.dart';

/// CapCut-style time / frame labels above the filmstrip.
class TimelineRulerPainter extends CustomPainter {
  TimelineRulerPainter({
    required this.sequenceDuration,
    required this.scrollPx,
    required this.contentWidth,
    required this.contentInsetX,
    required this.msPerPx,
    this.fps = timelineRulerFps,
  });

  final Duration sequenceDuration;
  final double scrollPx;
  final double contentWidth;
  final double contentInsetX;
  final double msPerPx;
  final int fps;

  double _x(Duration time) {
    return durationToContentX(time, sequenceDuration, contentWidth) -
        scrollPx +
        contentInsetX;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || msPerPx <= 0) return;

    final pxPerSecond = 1000.0 / msPerPx;
    final padMs = (msPerPx * 48).round().clamp(0, 1 << 30);
    final start = contentXToDuration(
      scrollPx - contentInsetX - 48,
      sequenceDuration,
      contentWidth,
    );
    final end = contentXToDuration(
      scrollPx - contentInsetX + size.width + 48,
      sequenceDuration,
      contentWidth,
    );
    final marks = buildTimelineRulerMarks(
      rangeStart: start - Duration(milliseconds: padMs),
      rangeEnd: end + Duration(milliseconds: padMs),
      pxPerSecond: pxPerSecond,
      fps: fps,
    );

    final style = TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.w500,
      color: AppTheme.muted.withValues(alpha: 0.92),
      height: 1.0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    for (final mark in marks) {
      final x = _x(mark.time);
      if (x < -40 || x > size.width + 40) continue;

      if (mark.kind == TimelineRulerMarkKind.minor || mark.label.isEmpty) {
        canvas.drawCircle(
          Offset(x, size.height * 0.55),
          1.1,
          Paint()..color = AppTheme.muted.withValues(alpha: 0.55),
        );
        continue;
      }

      final painter = TextPainter(
        text: TextSpan(text: mark.label, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final dx = x - painter.width / 2;
      final dy = (size.height - painter.height) / 2;
      painter.paint(canvas, Offset(dx, dy));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant TimelineRulerPainter oldDelegate) {
    return oldDelegate.sequenceDuration != sequenceDuration ||
        oldDelegate.scrollPx != scrollPx ||
        oldDelegate.contentWidth != contentWidth ||
        oldDelegate.contentInsetX != contentInsetX ||
        oldDelegate.msPerPx != msPerPx ||
        oldDelegate.fps != fps;
  }
}
