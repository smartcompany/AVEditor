import 'dart:math' as math;

/// Shared fade/volume math for music clips and source-video audio.
class AudioEnvelope {
  const AudioEnvelope({
    this.volume = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
  });

  final double volume;
  final Duration fadeIn;
  final Duration fadeOut;

  bool get isDefault =>
      volume >= 0.999 &&
      fadeIn <= Duration.zero &&
      fadeOut <= Duration.zero;

  (Duration, Duration) resolvedFades(Duration clipDuration) {
    var fi = fadeIn.isNegative ? Duration.zero : fadeIn;
    var fo = fadeOut.isNegative ? Duration.zero : fadeOut;
    final budgetMs =
        clipDuration.inMilliseconds - minAudioFadeGap.inMilliseconds;
    if (budgetMs <= 0) return (Duration.zero, Duration.zero);

    var fiMs = fi.inMilliseconds;
    var foMs = fo.inMilliseconds;
    if (fiMs < 0) fiMs = 0;
    if (foMs < 0) foMs = 0;

    if (fiMs + foMs > budgetMs) {
      final total = fiMs + foMs;
      fiMs = ((fiMs / total) * budgetMs).round();
      foMs = budgetMs - fiMs;
    }
    return (Duration(milliseconds: fiMs), Duration(milliseconds: foMs));
  }

  Duration maxFadeIn(Duration clipDuration) {
    final fo = fadeOut.isNegative ? Duration.zero : fadeOut;
    final foMs = fo.inMilliseconds.clamp(0, clipDuration.inMilliseconds);
    final maxMs =
        clipDuration.inMilliseconds - foMs - minAudioFadeGap.inMilliseconds;
    if (maxMs <= 0) return Duration.zero;
    return Duration(milliseconds: maxMs);
  }

  Duration maxFadeOut(Duration clipDuration) {
    final fi = fadeIn.isNegative ? Duration.zero : fadeIn;
    final fiMs = fi.inMilliseconds.clamp(0, clipDuration.inMilliseconds);
    final maxMs =
        clipDuration.inMilliseconds - fiMs - minAudioFadeGap.inMilliseconds;
    if (maxMs <= 0) return Duration.zero;
    return Duration(milliseconds: maxMs);
  }

  /// Gain at [localOffset] within a clip of [clipDuration] (half-cosine fades).
  double volumeAt(Duration localOffset, Duration clipDuration) {
    final base = volume.clamp(0.0, 1.0);
    final t = localOffset.inMilliseconds.toDouble();
    final dur = clipDuration.inMilliseconds.toDouble();
    if (dur <= 0) return 0;
    final fades = resolvedFades(clipDuration);
    final fi = fades.$1.inMilliseconds.toDouble();
    final fo = fades.$2.inMilliseconds.toDouble();

    var gain = 1.0;
    if (fi > 0 && t < fi) {
      gain = roundFadeGain(t / fi);
    }
    if (fo > 0 && t > dur - fo) {
      final outGain = roundFadeGain((dur - t) / fo);
      gain = gain < outGain ? gain : outGain;
    }
    return base * gain;
  }

  static double roundFadeGain(double linear01) {
    final t = linear01.clamp(0.0, 1.0);
    return 0.5 - 0.5 * math.cos(math.pi * t);
  }

  /// Volume / fade only — native export applies these on-device.
  AudioEnvelope copyWith({
    double? volume,
    Duration? fadeIn,
    Duration? fadeOut,
  }) {
    return AudioEnvelope(
      volume: volume ?? this.volume,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
    );
  }
}

const minAudioFadeGap = Duration(milliseconds: 80);
