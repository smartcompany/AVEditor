import 'dart:io';

import 'package:aveditor/services/playback_fallback_transcoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hevc on Android goes straight to ffmpeg', () {
    expect(
      PlaybackFallbackTranscoder.needsDirectTranscode('hevc', android: true),
      isTrue,
    );
    expect(
      PlaybackFallbackTranscoder.needsDirectTranscode('prores', android: true),
      isTrue,
    );
    expect(
      PlaybackFallbackTranscoder.needsDirectTranscode('h264', android: true),
      isFalse,
    );
    expect(
      PlaybackFallbackTranscoder.needsDirectTranscode('hevc', android: false),
      isFalse,
    );
  });

  test('arguments encode H.264 and keep an optional audio stream', () {
    final args = PlaybackFallbackTranscoder.arguments(
      '/clips/source.mov',
      '/clips/.source.transcode.mp4',
    );

    expect(args, contains('libx264'));
    expect(args, contains('yuv420p'));
    expect(args, contains('0:a:0?'));
    expect(args.first, '-y');
    expect(args.last, '/clips/.source.transcode.mp4');
  });

  test('transcode replaces a mov source with source.mp4', () async {
    final directory = await Directory.systemTemp.createTemp('playback-fallback');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.mov');
    await source.writeAsString('original');

    final transcoder = PlaybackFallbackTranscoder(
      run: (arguments) async {
        await File(arguments.last).writeAsString('h264');
        return true;
      },
    );

    final output = await transcoder.transcode(source.path);

    expect(output, '${directory.path}/source.mp4');
    expect(await File(output).readAsString(), 'h264');
    expect(await source.exists(), isFalse);
    expect(await File('${directory.path}/.source.transcode.mp4').exists(), isFalse);
  });

  test('transcode replaces an mp4 source in place', () async {
    final directory = await Directory.systemTemp.createTemp('playback-fallback');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.mp4');
    await source.writeAsString('hevc');

    final transcoder = PlaybackFallbackTranscoder(
      run: (arguments) async {
        await File(arguments.last).writeAsString('h264');
        return true;
      },
    );

    final output = await transcoder.transcode(source.path);

    expect(output, source.path);
    expect(await File(output).readAsString(), 'h264');
    expect(await File('${source.path}.playback-bak').exists(), isFalse);
  });

  test('failed transcode leaves the original file in place', () async {
    final directory = await Directory.systemTemp.createTemp('playback-fallback');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.mov');
    await source.writeAsString('original');

    final transcoder = PlaybackFallbackTranscoder(run: (_) async => false);

    await expectLater(
      transcoder.transcode(source.path),
      throwsA(isA<StateError>()),
    );
    expect(await source.readAsString(), 'original');
  });
}
