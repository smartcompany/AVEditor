import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAudioMixGraph', () {
    test('mixes video audio with delayed background music', () {
      final graph = ExportService.buildAudioMixGraph(
        music: ProjectMusic(
          title: 'bgm',
          fileName: 'music.mp3',
          timelineStart: const Duration(seconds: 2),
          sourceOffset: const Duration(seconds: 1),
          volume: 0.5,
        ),
        trimStart: Duration.zero,
        exportDurationSec: 10,
        videoAudioStream: '[0:a]',
        musicInput: 1,
      );

      expect(graph.outputLabel, 'aout');
      expect(graph.description, contains('[0:a]'));
      expect(graph.description, contains('[1:a]'));
      expect(graph.description, contains('amix=inputs=2'));
      expect(graph.description, contains('adelay=2000|2000'));
    });

    test('uses music only when the clip has no audio', () {
      final graph = ExportService.buildAudioMixGraph(
        music: ProjectMusic(
          title: 'bgm',
          fileName: 'music.mp3',
        ),
        trimStart: Duration.zero,
        exportDurationSec: 8,
        videoAudioStream: '[acat]',
        musicInput: 1,
        hasVideoAudio: false,
      );

      expect(graph.description, isNot(contains('amix')));
      expect(graph.description, contains('[aout]'));
    });
  });

  group('canStreamCopy', () {
    test('background music disables stream copy', () {
      expect(
        ExportService.canStreamCopy(
          project: _emptyProject(),
          rasters: const [],
          quality: ExportQualityProfile.recommended,
          musicPath: '/tmp/music.mp3',
        ),
        isFalse,
      );
    });
  });
}

VideoProject _emptyProject() {
  return VideoProject(
    id: 'p',
    sourcePath: '/tmp/p/source.mp4',
    duration: const Duration(seconds: 10),
  );
}
