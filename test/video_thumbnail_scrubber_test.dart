import 'package:aveditor/widgets/video_thumbnail_scrubber.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('touch position maps to a clamped playback position', () {
    const duration = Duration(seconds: 10);
    expect(
      VideoThumbnailScrubber.positionAt(50, 200, duration),
      const Duration(milliseconds: 2500),
    );
    expect(
      VideoThumbnailScrubber.positionAt(-20, 200, duration),
      Duration.zero,
    );
    expect(VideoThumbnailScrubber.positionAt(400, 200, duration), duration);
    expect(VideoThumbnailScrubber.positionAt(10, 0, duration), Duration.zero);
  });

  test('frames are taken from the middle of equal slices', () {
    expect(VideoThumbnailScrubber.frameTimesMs(const Duration(seconds: 6), 3), [
      1000,
      3000,
      5000,
    ]);
    expect(VideoThumbnailScrubber.frameTimesMs(Duration.zero, 3), isEmpty);
  });
}
