import 'package:aveditor/utils/timeline_ruler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('zoomed out uses second labels without frame marks', () {
    final marks = buildTimelineRulerMarks(
      rangeStart: Duration.zero,
      rangeEnd: const Duration(seconds: 8),
      pxPerSecond: 24, // too tight for 10f
      fps: 30,
    );
    expect(marks.where((m) => m.kind == TimelineRulerMarkKind.frame), isEmpty);
    expect(
      marks.where((m) => m.kind == TimelineRulerMarkKind.second).length,
      greaterThanOrEqualTo(4),
    );
  });

  test('zoomed in inserts 10f / 20f between seconds at 30fps', () {
    final marks = buildTimelineRulerMarks(
      rangeStart: Duration.zero,
      rangeEnd: const Duration(seconds: 2),
      pxPerSecond: 120,
      fps: 30,
    );
    final labels = marks.map((m) => m.label).toList();
    expect(labels, contains('00:00'));
    expect(labels, contains('10f'));
    expect(labels, contains('20f'));
    expect(labels, contains('00:01'));
  });

  test('mid-second dots appear when frames do not fit but halves do', () {
    final marks = buildTimelineRulerMarks(
      rangeStart: Duration.zero,
      rangeEnd: const Duration(seconds: 2),
      pxPerSecond: 48, // ~half-second dots, not 10f
      fps: 30,
      minLabelSpacingPx: 36,
      minMinorSpacingPx: 14,
    );
    expect(marks.where((m) => m.kind == TimelineRulerMarkKind.frame), isEmpty);
    expect(
      marks.where((m) => m.kind == TimelineRulerMarkKind.minor).length,
      greaterThanOrEqualTo(1),
    );
  });
}
