import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
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

  test('signature never hard-joins different mediaIds', () {
    final sameRange = [
      ClipSegment(
        mediaId: 'a',
        start: Duration.zero,
        end: const Duration(milliseconds: 1500),
      ),
      ClipSegment(
        mediaId: 'b',
        start: const Duration(milliseconds: 1500),
        end: const Duration(milliseconds: 4000),
      ),
    ];
    final joined = timelineCompositionSignature([
      ClipSegment(
        mediaId: 'a',
        start: Duration.zero,
        end: const Duration(milliseconds: 1500),
      ),
      ClipSegment(
        mediaId: 'a',
        start: const Duration(milliseconds: 1500),
        end: const Duration(milliseconds: 4000),
      ),
    ]);
    expect(timelineCompositionSignature(sameRange), isNot(joined));
    expect(timelineCompositionSignature(sameRange).contains('a:'), isTrue);
    expect(timelineCompositionSignature(sameRange).contains('b:'), isTrue);
  });

  test('encodeCompositionSegments includes per-asset path and kind', () {
    final video = MediaAsset(
      id: 'v1',
      fileName: 'media/v1.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 5),
    );
    final image = MediaAsset(
      id: 'i1',
      fileName: 'media/i1.jpg',
      kind: MediaAssetKind.image,
    );
    final project = VideoProject(
      id: 'p',
      sourcePath: '/tmp/p/media/v1.mp4',
      duration: const Duration(seconds: 8),
      mediaAssets: [video, image],
      segments: [
        ClipSegment(
          mediaId: video.id,
          start: Duration.zero,
          end: const Duration(seconds: 5),
        ),
        ClipSegment(
          mediaId: image.id,
          start: Duration.zero,
          end: const Duration(seconds: 3),
        ),
      ],
    );

    final encoded = encodeCompositionSegments(
      project.segments,
      project: project,
    );
    expect(encoded, hasLength(2));
    expect(encoded[0]['sourcePath'], endsWith('media/v1.mp4'));
    expect(encoded[0]['kind'], 'video');
    expect(encoded[0]['durationMs'], 5000);
    expect(encoded[1]['sourcePath'], endsWith('media/i1.jpg'));
    expect(encoded[1]['kind'], 'image');
    expect(encoded[1]['durationMs'], 3000);
  });
}
