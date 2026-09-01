import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ClipSegment seg(Duration start, Duration end, {String id = 's'}) {
    return ClipSegment(id: id, start: start, end: end);
  }

  test('splitSegmentsAt divides one segment into two', () {
    final result = splitSegmentsAt(
      [seg(Duration.zero, const Duration(seconds: 10), id: 'a')],
      const Duration(seconds: 4),
    );

    expect(result.length, 2);
    expect(result[0].start, Duration.zero);
    expect(result[0].end, const Duration(seconds: 4));
    expect(result[1].start, const Duration(seconds: 4));
    expect(result[1].end, const Duration(seconds: 10));
  });

  test('deleteSegment removes a middle segment', () {
    final result = deleteSegment(
      [
        seg(Duration.zero, const Duration(seconds: 3), id: 'a'),
        seg(const Duration(seconds: 3), const Duration(seconds: 7), id: 'b'),
        seg(const Duration(seconds: 7), const Duration(seconds: 10), id: 'c'),
      ],
      'b',
    );

    expect(result.length, 2);
    expect(result.map((s) => s.id), ['a', 'c']);
  });

  test('deleteSegment rejects an empty segment list', () {
    expect(
      () => deleteSegment([], 'missing'),
      throwsA(
        predicate<StateError>((error) => error.message == 'cannot_delete_last_segment'),
      ),
    );
  });

  test('sourceTimeToExportTime skips deleted gaps', () {
    final segments = [
      seg(Duration.zero, const Duration(seconds: 3)),
      seg(const Duration(seconds: 7), const Duration(seconds: 10)),
    ];

    expect(
      sourceTimeToExportTime(segments, const Duration(seconds: 8)),
      const Duration(seconds: 4),
    );
    expect(sourceTimeToExportTime(segments, const Duration(seconds: 5)), isNull);
  });

  test('overlayKeptRanges clips to kept segments without duplicating layers', () {
    final overlay = TextOverlay(
      text: 'hello',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 8),
    );
    final segments = [
      seg(Duration.zero, const Duration(seconds: 3)),
      seg(const Duration(seconds: 7), const Duration(seconds: 10)),
    ];

    final ranges = overlayKeptRanges(overlay, segments);

    expect(ranges.length, 2);
    expect(ranges[0].start, const Duration(seconds: 1));
    expect(ranges[0].end, const Duration(seconds: 3));
    expect(ranges[1].start, const Duration(seconds: 7));
    expect(ranges[1].end, const Duration(seconds: 8));
  });

  test('isOverlayVisibleAt hides text in deleted gaps', () {
    final overlay = TextOverlay(
      text: 'hello',
      start: Duration.zero,
      end: const Duration(seconds: 10),
    );
    final segments = [
      seg(Duration.zero, const Duration(seconds: 3)),
      seg(const Duration(seconds: 7), const Duration(seconds: 10)),
    ];

    expect(
      isOverlayVisibleAt(overlay, segments, const Duration(seconds: 2)),
      isTrue,
    );
    expect(
      isOverlayVisibleAt(overlay, segments, const Duration(seconds: 5)),
      isFalse,
    );
    expect(
      isOverlayVisibleAt(overlay, segments, const Duration(seconds: 8)),
      isTrue,
    );
  });

  test('overlayExportSpans emits separate export windows across deleted gaps', () {
    final overlay = TextOverlay(
      text: 'hello',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 8),
    );
    final segments = [
      seg(Duration.zero, const Duration(seconds: 3)),
      seg(const Duration(seconds: 7), const Duration(seconds: 10)),
    ];

    final spans = overlayExportSpans(overlay, segments);

    expect(spans.length, 2);
    expect(spans[0].start, closeTo(1.0, 0.001));
    expect(spans[0].end, closeTo(3.0, 0.001));
    expect(spans[1].start, closeTo(3.0, 0.001));
    expect(spans[1].end, closeTo(4.0, 0.001));
  });

  test('exportTimeToSourceTime maps packed timeline positions', () {
    final segments = [
      seg(Duration.zero, const Duration(seconds: 3)),
      seg(const Duration(seconds: 7), const Duration(seconds: 10)),
    ];

    expect(
      exportTimeToSourceTime(segments, const Duration(seconds: 4)),
      const Duration(seconds: 8),
    );
    expect(
      timelinePlayheadFromSource(segments, const Duration(seconds: 5)),
      const Duration(seconds: 3),
    );
  });
}
