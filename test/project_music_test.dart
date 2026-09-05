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
      source: MusicSource.pixabay,
      externalId: 'pixabay-123',
    );

    final project = VideoProject(
      id: 'p1',
      sourcePath: '/tmp/p1/source.mp4',
      duration: const Duration(seconds: 30),
      musicTracks: [music],
    );

    final restored = VideoProject.fromJson(
      project.toJson(),
      sourcePath: project.sourcePath,
    );

    expect(restored.musicTracks.single.title, 'Chill beat');
    expect(restored.musicTracks.single.artist, 'Artist');
    expect(restored.musicTracks.single.source, MusicSource.pixabay);
    expect(restored.musicTracks.single.volume, 0.7);
  });

  test('legacy jamendo source still round-trips', () {
    final music = ProjectMusic(
      title: 'Old track',
      fileName: 'music.mp3',
      source: MusicSource.jamendo,
      externalId: '99',
    );
    final restored = ProjectMusic.fromJson(music.toJson());
    expect(restored.source, MusicSource.jamendo);
  });

  test('fade in can span almost to fade out across the clip', () {
    final music = ProjectMusic(
      title: 'Long fade',
      fileName: 'music.mp3',
      fileDuration: const Duration(seconds: 20),
      clipDuration: const Duration(seconds: 10),
      fadeIn: const Duration(seconds: 9),
      fadeOut: const Duration(milliseconds: 500),
      volume: 1,
    );

    expect(music.maxFadeIn, greaterThan(const Duration(seconds: 8)));
    expect(
      music.effectiveFadeIn.inMilliseconds + music.effectiveFadeOut.inMilliseconds,
      lessThanOrEqualTo(
        music.clipDuration.inMilliseconds - minMusicFadeGap.inMilliseconds,
      ),
    );
    expect(music.effectiveFadeIn, greaterThan(const Duration(seconds: 8)));
  });

  test('volume envelope uses a rounded fade curve', () {
    final music = ProjectMusic(
      title: 'Curve',
      fileName: 'music.mp3',
      clipDuration: const Duration(seconds: 4),
      fadeIn: const Duration(seconds: 2),
      fadeOut: const Duration(seconds: 2),
      volume: 1,
    );

    final midIn = music.volumeAt(const Duration(seconds: 1));
    // Half-cosine starts gentler than linear, then steepens — round cover.
    final quarter = music.volumeAt(const Duration(milliseconds: 500));
    expect(quarter, lessThan(0.25));
    expect(quarter, greaterThan(0.1));
    expect(midIn, closeTo(0.5, 0.02));
    expect(music.volumeAt(Duration.zero), closeTo(0, 0.001));
    expect(music.volumeAt(const Duration(seconds: 2)), closeTo(1, 0.02));
  });

  test('overlapping music clips are assigned a new lane', () {
    final a = ProjectMusic(
      id: 'a',
      title: 'A',
      fileName: 'a.mp3',
      timelineStart: Duration.zero,
      clipDuration: const Duration(seconds: 10),
      lane: 0,
    );
    final b = ProjectMusic(
      id: 'b',
      title: 'B',
      fileName: 'b.mp3',
      timelineStart: const Duration(seconds: 4),
      clipDuration: const Duration(seconds: 10),
      lane: 0,
    );

    final placed = assignMusicLane([a], b);
    expect(placed.lane, 1);
    expect(musicLaneCount([a, placed]), 2);
  });

  test('non-overlapping clips pack up onto the free upper lane', () {
    final a = ProjectMusic(
      id: 'a',
      title: 'A',
      fileName: 'a.mp3',
      timelineStart: Duration.zero,
      clipDuration: const Duration(seconds: 4),
      lane: 0,
    );
    final b = ProjectMusic(
      id: 'b',
      title: 'B',
      fileName: 'b.mp3',
      timelineStart: const Duration(seconds: 10),
      clipDuration: const Duration(seconds: 4),
      lane: 1,
    );

    final placed = assignMusicLane([a], b);
    expect(placed.lane, 0);
  });

  test('sticky mode keeps the lower lane when preferLowestLane is false', () {
    final a = ProjectMusic(
      id: 'a',
      title: 'A',
      fileName: 'a.mp3',
      timelineStart: Duration.zero,
      clipDuration: const Duration(seconds: 4),
      lane: 0,
    );
    final b = ProjectMusic(
      id: 'b',
      title: 'B',
      fileName: 'b.mp3',
      timelineStart: const Duration(seconds: 10),
      clipDuration: const Duration(seconds: 4),
      lane: 1,
    );

    final placed = assignMusicLane([a], b, preferLowestLane: false);
    expect(placed.lane, 1);
  });

  test('lane survives project json round-trip', () {
    final music = ProjectMusic(
      title: 'Lane',
      fileName: 'music.mp3',
      lane: 2,
    );
    final restored = ProjectMusic.fromJson(music.toJson());
    expect(restored.lane, 2);
  });
}
