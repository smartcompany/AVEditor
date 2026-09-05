import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

class AudioWaveformData {
  const AudioWaveformData({
    required this.peaks,
    required this.duration,
  });

  final List<double> peaks;
  final Duration duration;
}

/// Builds normalized 0..1 peak bars for timeline waveforms.
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

    final rawPath = p.join(
      Directory.systemTemp.path,
      'aveditor_wf_${stat.size}_${stat.modified.millisecondsSinceEpoch}.s16le',
    );

    try {
      const sampleRate = 8000;
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        audioPath,
        '-ac',
        '1',
        '-ar',
        '$sampleRate',
        '-f',
        's16le',
        '-acodec',
        'pcm_s16le',
        rawPath,
      ]);
      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code)) {
        return null;
      }

      final bytes = await File(rawPath).readAsBytes();
      final sampleCount = bytes.length ~/ 2;
      if (sampleCount <= 0) return null;

      final duration = Duration(
        milliseconds: ((sampleCount / sampleRate) * 1000).round(),
      );
      final peaks = _peaksFromS16le(bytes, peakCount);
      final data = AudioWaveformData(peaks: peaks, duration: duration);
      _cache[key] = data;
      return data;
    } catch (_) {
      return null;
    } finally {
      try {
        final raw = File(rawPath);
        if (await raw.exists()) await raw.delete();
      } catch (_) {}
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

  static List<double> _peaksFromS16le(Uint8List bytes, int peakCount) {
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount <= 0 || peakCount <= 0) return const [];

    final bucket = math.max(1, sampleCount ~/ peakCount);
    final peaks = List<double>.filled(peakCount, 0);
    final data = ByteData.sublistView(bytes);

    for (var i = 0; i < peakCount; i++) {
      final start = i * bucket;
      if (start >= sampleCount) break;
      var maxAbs = 0;
      final end = math.min(start + bucket, sampleCount);
      for (var s = start; s < end; s++) {
        final v = data.getInt16(s * 2, Endian.little).abs();
        if (v > maxAbs) maxAbs = v;
      }
      peaks[i] = (maxAbs / 32768.0).clamp(0.0, 1.0);
    }

    var tallest = 0.0;
    for (final peak in peaks) {
      if (peak > tallest) tallest = peak;
    }
    if (tallest > 0.05) {
      final scale = 1.0 / tallest;
      for (var i = 0; i < peaks.length; i++) {
        peaks[i] = (peaks[i] * scale).clamp(0.0, 1.0);
      }
    }
    return peaks;
  }
}
