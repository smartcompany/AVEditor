import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a YouTube video id from a link', () {
    expect(youtubeVideoId('dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(
      youtubeVideoId('https://youtu.be/dQw4w9WgXcQ'),
      'dQw4w9WgXcQ',
    );
    expect(
      youtubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
      'dQw4w9WgXcQ',
    );
    expect(
      youtubeVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      'dQw4w9WgXcQ',
    );
    expect(youtubeVideoId('not a video'), isNull);
    expect(youtubeVideoId(''), isNull);
  });

  test('splits tags and keeps the YouTube character budget', () {
    expect(youtubeTags(' cats, dogs '), ['cats', 'dogs']);
    expect(youtubeTags(''), isEmpty);
    expect(youtubeTags('a' * 501), isEmpty);
  });
}
