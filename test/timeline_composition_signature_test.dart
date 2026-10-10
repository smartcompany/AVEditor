import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/services/composition_segments.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('splitting a clip does not change the preview composition', () {
    final whole = [
      ClipSegment(
        start: Duration.zero,
        end: const Duration(milliseconds: 4000),
      ),
    ];
    final split = splitSegmentsAt(whole, const Duration(milliseconds: 1500));

    expect(split, hasLength(2));
    expect(
      timelineCompositionSignature(split),
      timelineCompositionSignature(whole),
    );
  });

  test('a gap changes the preview composition', () {
    final contiguous = timelineCompositionSignature([
      ClipSegment(
        start: Duration.zero,
        end: const Duration(milliseconds: 1500),
      ),
      ClipSegment(
        start: const Duration(milliseconds: 1500),
        end: const Duration(milliseconds: 4000),
      ),
    ]);
    final gapped = timelineCompositionSignature([
      ClipSegment(
        start: Duration.zero,
        end: const Duration(milliseconds: 1500),
      ),
      ClipSegment(
        start: const Duration(milliseconds: 2500),
        end: const Duration(milliseconds: 4000),
      ),
    ]);

    expect(gapped, isNot(contiguous));
  });

  test('a transition changes the preview composition', () {
    final split = splitSegmentsAt(
      [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(milliseconds: 4000),
        ),
      ],
      const Duration(milliseconds: 2000),
    );
    final withTransition = [
      split[0].copyWith(
        transitionId: 'fade',
        transitionDuration: const Duration(milliseconds: 500),
      ),
      split[1],
    ];

    expect(
      timelineCompositionSignature(withTransition),
      isNot(timelineCompositionSignature(split)),
    );
  });
}
