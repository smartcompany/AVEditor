import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/utils/music_timeline_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projectSequenceDuration grows when music extends past video', () {
    final segments = [
      ClipSegment(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      ),
    ];
    final music = ProjectMusic(
      title: 'Long track',
      fileName: 'a.mp3',
      timelineStart: const Duration(seconds: 5),
      clipDuration: const Duration(seconds: 20),
      fileDuration: const Duration(seconds: 30),
    );

    expect(
      projectSequenceDuration(
        segments: segments,
        sourceDuration: const Duration(seconds: 10),
        musicTracks: [music],
      ),
      const Duration(seconds: 25),
    );
  });

  test('projectMaxScrubSourceTime allows scrub past video EOF', () {
    final segments = [
      ClipSegment(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      ),
    ];
    final music = ProjectMusic(
      title: 'Long track',
      fileName: 'a.mp3',
      timelineStart: const Duration(seconds: 8),
      clipDuration: const Duration(seconds: 12),
      fileDuration: const Duration(seconds: 30),
    );

    final maxScrub = projectMaxScrubSourceTime(
      segments: segments,
      sourceDuration: const Duration(seconds: 10),
      musicTracks: [music],
    );
    // Content ends at 20s (music past video). Edit pad is not scrubbable.
    expect(maxScrub, const Duration(seconds: 20));
  });
}
