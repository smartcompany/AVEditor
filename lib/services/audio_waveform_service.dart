import 'dart:io';

import 'package:aveditor/services/media_concat_service.dart';
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

  /// True when [peaks] look like real amplitude, not a flat no-audio filler.
  static bool looksLikeRealAudio(List<double> peaks) {
    if (peaks.isEmpty) return false;
    var max = 0.0;
    var min = 1.0;
    for (final p in peaks) {
      if (p > max) max = p;
      if (p < min) min = p;
    }
    // Legacy native fillers were flat ~0.05 / ~0.08 with no variation.
    if (max < 0.12 && (max - min) < 0.03) return false;
    return max > 0.02;
  }

  /// Returns peaks + decoded duration for [audioPath], or null on failure.
  Future<AudioWaveformData?> waveformForFile(
    String audioPath, {
    int peakCount = 240,
  }) async {
    final file = File(audioPath);
    if (!await file.exists()) return null;
    // Stills never carry an audio stream — don't invent a waveform.
    if (MediaConcatService.isImagePath(audioPath)) return null;

    final stat = await file.stat();
    final key =
        '$audioPath:${stat.size}:${stat.modified.millisecondsSinceEpoch}:$peakCount';
    final cached = _cache[key];
    if (cached != null) {
      return looksLikeRealAudio(cached.peaks) ? cached : null;
    }

    try {
      final decoded = await NativeVideoEngine.instance.decodeWaveform(
        audioPath,
        peakCount: peakCount,
      );
      if (decoded == null || decoded.peaks.isEmpty) return null;
      if (!looksLikeRealAudio(decoded.peaks)) return null;
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
