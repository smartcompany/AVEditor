import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ProjectMusic round-trips through project json', () {
    final music = ProjectMusic(
      title: 'Chill beat',
      artist: 'Artist',
      fileName: 'music.mp3',
      timelineStart: const Duration(seconds: 2),
      sourceOffset: const Duration(seconds: 5),
      volume: 0.7,
      licenseUrl: 'https://creativecommons.org/licenses/by/3.0/',
      source: MusicSource.jamendo,
      externalId: '123',
    );

    final project = VideoProject(
      id: 'p1',
      sourcePath: '/tmp/p1/source.mp4',
      duration: const Duration(seconds: 30),
      backgroundMusic: music,
    );

    final restored = VideoProject.fromJson(
      project.toJson(),
      sourcePath: project.sourcePath,
    );

    expect(restored.backgroundMusic?.title, 'Chill beat');
    expect(restored.backgroundMusic?.artist, 'Artist');
    expect(restored.backgroundMusic?.source, MusicSource.jamendo);
    expect(restored.backgroundMusic?.volume, 0.7);
  });
}
