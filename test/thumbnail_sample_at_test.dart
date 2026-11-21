import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/thumbnail_editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('thumbnailSampleAt uses the clip file for that timeline time', () {
    final a = MediaAsset(
      id: 'a',
      fileName: 'media/a.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 1),
    );
    final b = MediaAsset(
      id: 'b',
      fileName: 'media/b.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 4),
    );
    final project = VideoProject(
      id: 'p',
      sourcePath: '/tmp/projects/p/media/a.mp4',
      duration: const Duration(seconds: 5),
      mediaAssets: [a, b],
      segments: [
        ClipSegment(
          id: 's1',
          mediaId: a.id,
          start: Duration.zero,
          end: const Duration(seconds: 1),
        ),
        ClipSegment(
          id: 's2',
          mediaId: b.id,
          start: Duration.zero,
          end: const Duration(seconds: 4),
        ),
      ],
    );

    final early = thumbnailSampleAt(project, 200);
    expect(early.path, endsWith('media/a.mp4'));
    expect(early.timeMs, 200);

    final late = thumbnailSampleAt(project, 1500);
    expect(late.path, endsWith('media/b.mp4'));
    expect(late.timeMs, 500);
  });

  test('thumbnailSampleAt clamps to media duration', () {
    final a = MediaAsset(
      id: 'a',
      fileName: 'media/a.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(milliseconds: 1020),
    );
    final project = VideoProject(
      id: 'p',
      sourcePath: '/tmp/projects/p/media/a.mp4',
      duration: const Duration(milliseconds: 1020),
      mediaAssets: [a],
      segments: [
        ClipSegment(
          id: 's1',
          mediaId: a.id,
          start: Duration.zero,
          end: const Duration(milliseconds: 1020),
        ),
      ],
    );

    final sample = thumbnailSampleAt(project, 5000);
    expect(sample.path, endsWith('media/a.mp4'));
    expect(sample.timeMs, 1019);
  });
}
