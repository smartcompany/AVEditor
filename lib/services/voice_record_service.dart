import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// Thin wrapper around [AudioRecorder] for timeline voice-over takes.
class VoiceRecordService {
  VoiceRecordService({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  String? _activePath;

  Future<bool> ensurePermission() => _recorder.hasPermission();

  /// Starts an AAC recording into a temp file. Returns the path being written.
  Future<String> start() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'voice_${const Uuid().v4()}.m4a');
    _activePath = path;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  /// Stops and returns the recorded file path, or null if nothing was written.
  Future<String?> stop() async {
    final stopped = await _recorder.stop();
    final path = stopped ?? _activePath;
    _activePath = null;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) return null;
    return path;
  }

  Future<void> cancel() async {
    try {
      await _recorder.cancel();
    } catch (_) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    final path = _activePath;
    _activePath = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> dispose() => _recorder.dispose();
}
