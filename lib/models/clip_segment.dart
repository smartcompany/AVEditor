import 'package:aveditor/models/audio_envelope.dart';
import 'package:uuid/uuid.dart';

/// Default crossfade length when a transition is applied at a cut.
const defaultTransitionDuration = Duration(milliseconds: 500);

/// A kept portion of the source clip, in source-timeline order.
class ClipSegment {
  ClipSegment({
    String? id,
    required this.start,
    required this.end,
    this.volume = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.transitionId,
    this.transitionDuration = defaultTransitionDuration,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final Duration start;
  final Duration end;

  /// Source-video audio level for this segment (iMovie-style).
  final double volume;
  final Duration fadeIn;
  final Duration fadeOut;

  /// Transition applied **after** this segment into the next one.
  /// Null / empty / `none` = hard cut. Ignored on the last segment.
  final String? transitionId;

  /// Crossfade length for [transitionId] (clamped at export time).
  final Duration transitionDuration;

  Duration get duration => end - start;

  bool get hasTransition {
    final id = transitionId?.trim() ?? '';
    return id.isNotEmpty && id != 'none';
  }

  AudioEnvelope get audioEnvelope => AudioEnvelope(
        volume: volume,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
      );

  Duration get effectiveFadeIn => audioEnvelope.resolvedFades(duration).$1;
  Duration get effectiveFadeOut => audioEnvelope.resolvedFades(duration).$2;
  Duration get maxFadeIn => audioEnvelope.maxFadeIn(duration);
  Duration get maxFadeOut => audioEnvelope.maxFadeOut(duration);

  double volumeAt(Duration localOffset) =>
      audioEnvelope.volumeAt(localOffset, duration);

  Map<String, dynamic> toJson() => {
        'id': id,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'volume': volume,
        'fadeInMs': fadeIn.inMilliseconds,
        'fadeOutMs': fadeOut.inMilliseconds,
        if (transitionId != null && transitionId!.isNotEmpty)
          'transitionId': transitionId,
        'transitionMs': transitionDuration.inMilliseconds,
      };

  factory ClipSegment.fromJson(Map<String, dynamic> json) {
    return ClipSegment(
      id: json['id'] as String,
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      fadeIn: Duration(milliseconds: json['fadeInMs'] as int? ?? 0),
      fadeOut: Duration(milliseconds: json['fadeOutMs'] as int? ?? 0),
      transitionId: json['transitionId'] as String?,
      transitionDuration: Duration(
        milliseconds:
            json['transitionMs'] as int? ?? defaultTransitionDuration.inMilliseconds,
      ),
    );
  }

  ClipSegment copyWith({
    String? id,
    Duration? start,
    Duration? end,
    double? volume,
    Duration? fadeIn,
    Duration? fadeOut,
    String? transitionId,
    Duration? transitionDuration,
    bool clearTransition = false,
  }) {
    return ClipSegment(
      id: id ?? this.id,
      start: start ?? this.start,
      end: end ?? this.end,
      volume: volume ?? this.volume,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      transitionId: clearTransition ? null : (transitionId ?? this.transitionId),
      transitionDuration: transitionDuration ?? this.transitionDuration,
    );
  }
}
