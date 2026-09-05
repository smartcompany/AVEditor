import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cut transitions', () {
    test('nearestCutIndex picks closest packed cut', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 7),
        ),
        ClipSegment(
          start: const Duration(seconds: 7),
          end: const Duration(seconds: 10),
        ),
      ];

      expect(nearestCutIndex(segments, const Duration(seconds: 1)), 0);
      expect(nearestCutIndex(segments, const Duration(seconds: 4)), 0);
      expect(nearestCutIndex(segments, const Duration(seconds: 6)), 1);
    });

    test('exportTimelineDuration subtracts xfade overlaps', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      expect(totalKeptDuration(segments), const Duration(seconds: 6));
      expect(
        exportTimelineDuration(segments),
        const Duration(milliseconds: 5500),
      );
    });

    test('buildSegmentConcatGraph uses xfade when transition set', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 2),
          transitionId: 'dissolve',
          transitionDuration: const Duration(milliseconds: 400),
        ),
        ClipSegment(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 4),
        ),
      ];

      final graph = ExportService.buildSegmentConcatGraph(segments)!;
      expect(graph, contains('xfade=transition=dissolve'));
      expect(graph, contains('acrossfade=d=0.400'));
      expect(graph, contains('[vcat]'));
      expect(graph, contains('[acat]'));
    });

    test('transitionSequenceSpan centers on the cut', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      final span = transitionSequenceSpan(segments, 0)!;
      expect(span.start, const Duration(milliseconds: 2750));
      expect(span.end, const Duration(milliseconds: 3250));
    });

    test('buildSegmentConcatGraph keeps concat without transitions', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 2),
        ),
        ClipSegment(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 4),
        ),
      ];

      final graph = ExportService.buildSegmentConcatGraph(segments)!;
      expect(graph, contains('concat=n=2:v=1:a=1[vcat][acat]'));
      expect(graph, isNot(contains('xfade')));
    });
  });
}
