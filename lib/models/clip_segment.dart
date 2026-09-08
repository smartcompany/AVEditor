import 'package:aveditor/models/applied_transition.dart';
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
    AppliedTransition? transition,
    // Legacy constructors / call sites.
    String? transitionId,
    Duration? transitionDuration,
  })  : id = id ?? const Uuid().v4(),
        transition = _resolveTransition(
          transition: transition,
          transitionId: transitionId,
          transitionDuration: transitionDuration,
        );

  final String id;
  final Duration start;
  final Duration end;

  /// Source-video audio level for this segment (iMovie-style).
  final double volume;
  final Duration fadeIn;
  final Duration fadeOut;

  /// Transition applied **after** this segment into the next one.
  /// Null / none = hard cut. Ignored on the last segment.
  final AppliedTransition? transition;

  /// Legacy accessor — prefer [transition].
  String? get transitionId {
    final value = transition;
    if (value == null || value.isNone) return null;
    return value.id;
  }

  /// Legacy accessor — prefer [transition.duration].
  Duration get transitionDuration =>
      transition?.duration ?? defaultTransitionDuration;

  Duration get duration => end - start;

  bool get hasTransition {
    final value = transition;
    return value != null && !value.isNone;
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

  Map<String, dynamic> toJson() {
    final applied = transition;
    return {
      'id': id,
      'startMs': start.inMilliseconds,
      'endMs': end.inMilliseconds,
      'volume': volume,
      'fadeInMs': fadeIn.inMilliseconds,
      'fadeOutMs': fadeOut.inMilliseconds,
      if (applied != null && !applied.isNone) 'transition': applied.toJson(),
      // Dual-write for older builds / tools still reading flat fields.
      if (applied != null && !applied.isNone) 'transitionId': applied.id,
      'transitionMs':
          (applied?.duration ?? defaultTransitionDuration).inMilliseconds,
    };
  }

  factory ClipSegment.fromJson(Map<String, dynamic> json) {
    AppliedTransition? applied;
    final nested = json['transition'];
    if (nested is Map) {
      applied = AppliedTransition.fromJson(Map<String, dynamic>.from(nested));
    } else {
      applied = AppliedTransition.fromLegacy(
        transitionId: json['transitionId'] as String?,
        transitionMs: json['transitionMs'] as int?,
      );
      if (applied.isNone) applied = null;
    }

    return ClipSegment(
      id: json['id'] as String,
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      fadeIn: Duration(milliseconds: json['fadeInMs'] as int? ?? 0),
      fadeOut: Duration(milliseconds: json['fadeOutMs'] as int? ?? 0),
      transition: applied,
    );
  }

  ClipSegment copyWith({
    String? id,
    Duration? start,
    Duration? end,
    double? volume,
    Duration? fadeIn,
    Duration? fadeOut,
    AppliedTransition? transition,
    String? transitionId,
    Duration? transitionDuration,
    bool clearTransition = false,
  }) {
    AppliedTransition? next = transition;
    if (clearTransition) {
      next = null;
    } else if (transition == null &&
        (transitionId != null || transitionDuration != null)) {
      next = AppliedTransition(
        id: transitionId ?? this.transitionId ?? 'none',
        version: this.transition?.version ?? 1,
        duration: transitionDuration ?? this.transitionDuration,
        parameters: this.transition?.parameters ?? const {},
      );
      if (next.isNone) next = null;
    } else if (transition == null) {
      next = this.transition;
    }

    return ClipSegment(
      id: id ?? this.id,
      start: start ?? this.start,
      end: end ?? this.end,
      volume: volume ?? this.volume,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      transition: next,
    );
  }

  static AppliedTransition? _resolveTransition({
    AppliedTransition? transition,
    String? transitionId,
    Duration? transitionDuration,
  }) {
    if (transition != null) {
      return transition.isNone ? null : transition;
    }
    if (transitionId == null && transitionDuration == null) return null;
    final applied = AppliedTransition.fromLegacy(
      transitionId: transitionId,
      transitionMs: transitionDuration?.inMilliseconds,
    );
    return applied.isNone ? null : applied;
  }
}
