import 'dart:io';

import 'package:aveditor/services/native_video_engine.dart';

class AudioWaveformData {
  const AudioWaveformData({
    required this.peaks,
    required this.duration,
  });

  final List<double> peaks;
  final Duration duration;
}

/// Builds normalized 0..1 peak bars for timeline waveforms using the OS decoder.
class AudioWaveformService {
  AudioWaveformService._();
  static final instance = AudioWaveformService._();

  final Map<String, AudioWaveformData> _cache = {};

  /// Returns peaks + decoded duration for [audioPath], or null on failure.
  Future<AudioWaveformData?> waveformForFile(
    String audioPath, {
    int peakCount = 240,
  }) async {
    final file = File(audioPath);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final key =
        '$audioPath:${stat.size}:${stat.modified.millisecondsSinceEpoch}:$peakCount';
    final cached = _cache[key];
    if (cached != null) return cached;

    try {
      final decoded = await NativeVideoEngine.instance.decodeWaveform(
        audioPath,
        peakCount: peakCount,
      );
      if (decoded == null || decoded.peaks.isEmpty) return null;
      final data = AudioWaveformData(
        peaks: decoded.peaks,
        duration: decoded.duration,
      );
      _cache[key] = data;
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Kept for call sites that only need peaks.
  Future<List<double>> peaksForFile(
    String audioPath, {
    int peakCount = 240,
  }) async {
    final data = await waveformForFile(audioPath, peakCount: peakCount);
    return data?.peaks ?? const [];
  }

  void clear() => _cache.clear();
}
