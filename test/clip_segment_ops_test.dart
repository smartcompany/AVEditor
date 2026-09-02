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

  test('resolveSplitPoint nudges near segment edges instead of failing', () {
    final segments = [seg(Duration.zero, const Duration(seconds: 10))];

    expect(
      resolveSplitPoint(segments, const Duration(milliseconds: 50)),
      const Duration(milliseconds: 100),
    );
    expect(
      resolveSplitPoint(segments, const Duration(seconds: 9, milliseconds: 950)),
      const Duration(seconds: 9, milliseconds: 900),
    );
  });

  test('resolveSplitPoint allows splitting a one-second segment', () {
    final segments = [
      seg(const Duration(seconds: 164), const Duration(seconds: 165)),
    ];

    expect(
      resolveSplitPoint(
        segments,
        const Duration(seconds: 164, milliseconds: 750),
      ),
      const Duration(seconds: 164, milliseconds: 750),
    );
  });

  test('splitSourceFromSequence maps edited timeline position to source time', () {
    final segments = [
      seg(const Duration(seconds: 156), const Duration(seconds: 184)),
    ];

    expect(
      splitSourceFromSequence(segments, const Duration(seconds: 8)),
      const Duration(seconds: 163, milliseconds: 999),
    );
  });

  test('collapseMicroSegments merges accidental splinters', () {
    final segments = [
      seg(const Duration(seconds: 156), const Duration(seconds: 164, milliseconds: 750)),
      seg(
        const Duration(seconds: 164, milliseconds: 750),
        const Duration(seconds: 164, milliseconds: 800),
      ),
      seg(const Duration(seconds: 164, milliseconds: 800), const Duration(seconds: 184)),
    ];

    final merged = collapseMicroSegments(segments);

    expect(merged.length, 2);
    expect(merged[0].end, const Duration(seconds: 164, milliseconds: 800));
    expect(merged[1].start, const Duration(seconds: 164, milliseconds: 800));
  });

  test('collapseMicroSegments drops invalid segments before merging', () {
    final segments = [
      seg(const Duration(seconds: 167, milliseconds: 450), const Duration(seconds: 113)),
      seg(const Duration(seconds: 113), const Duration(seconds: 144, milliseconds: 550)),
    ];

    final merged = collapseMicroSegments(segments);

    expect(merged.length, 1);
    expect(merged.first.start, const Duration(seconds: 113));
    expect(merged.first.end, const Duration(seconds: 144, milliseconds: 550));
  });

  test('normalizeSegments repairs invalid project data', () {
    final segments = [
      seg(const Duration(seconds: 167, milliseconds: 450), const Duration(seconds: 113)),
      seg(const Duration(seconds: 113), const Duration(seconds: 144, milliseconds: 550)),
    ];

    final normalized = normalizeSegments(
      segments,
      sourceDuration: const Duration(seconds: 180),
    );

    expect(normalized.every((segment) => segment.duration > Duration.zero), isTrue);
    expect(normalized.first.start, const Duration(seconds: 113));
  });

  test('splitSegmentsAt works on a fresh single-segment project', () {
    final segments = [seg(Duration.zero, const Duration(seconds: 72))];
    final sequenceTime = const Duration(seconds: 12, milliseconds: 50);
    final playhead = splitSourceFromSequence(segments, sequenceTime);

    final splitPoint = resolveSplitPoint(segments, playhead);
    final result = splitSegmentsAt(segments, splitPoint);

    expect(result.length, 2);
    expect(result[0].end, splitPoint);
    expect(result[1].start, splitPoint);
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

  test('overlayTimelineRanges merges spans across contiguous split points', () {
    final overlay = TextOverlay(
      text: 'hello',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 8),
    );
    final segments = [
      seg(Duration.zero, const Duration(seconds: 4)),
      seg(const Duration(seconds: 4), const Duration(seconds: 10)),
    ];

    final ranges = overlayTimelineRanges(overlay, segments);

    expect(ranges.length, 1);
    expect(ranges.first.start, const Duration(seconds: 2));
    expect(ranges.first.end, const Duration(seconds: 8));
  });

  test('overlayTimelineSpan falls back when overlay starts before kept video', () {
    final overlay = TextOverlay(
      text: 'hello',
      start: Duration.zero,
      end: const Duration(seconds: 4),
    );
    final segments = [
      seg(const Duration(seconds: 2), const Duration(seconds: 10)),
    ];

    final span = overlayTimelineSpan(overlay, segments);

    expect(span, isNotNull);
    expect(span!.start, Duration.zero);
    expect(span.end, const Duration(seconds: 2));
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
