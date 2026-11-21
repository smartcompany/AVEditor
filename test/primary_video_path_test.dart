import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primaryVideoPath prefers first timeline video over orphan assets', () {
    final wide = MediaAsset(
      id: 'wide',
      fileName: 'media/wide.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 4),
    );
    final portrait = MediaAsset(
      id: 'portrait',
      fileName: 'media/portrait.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 3),
    );
    final project = VideoProject(
      id: 'p1',
      sourcePath: '/tmp/projects/p1/media/wide.mp4',
      duration: const Duration(seconds: 3),
      mediaAssets: [wide, portrait],
      segments: [
        ClipSegment(
          id: 's1',
          mediaId: portrait.id,
          start: Duration.zero,
          end: const Duration(seconds: 3),
        ),
      ],
    );

    expect(project.primaryVideoPath, endsWith('media/portrait.mp4'));
  });

  test('primaryVideoPath falls back to first video asset when timeline empty', () {
    final wide = MediaAsset(
      id: 'wide',
      fileName: 'media/wide.mp4',
      kind: MediaAssetKind.video,
      duration: const Duration(seconds: 4),
    );
    final project = VideoProject(
      id: 'p1',
      sourcePath: '/tmp/projects/p1/media/wide.mp4',
      duration: Duration.zero,
      mediaAssets: [wide],
      segments: const [],
    );

    expect(project.primaryVideoPath, endsWith('media/wide.mp4'));
  });
}
