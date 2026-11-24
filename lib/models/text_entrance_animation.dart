import 'dart:math' as math;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/foundation.dart';

/// Built-in entrance / continuous motion ids the client knows how to paint/export.
abstract final class TextEntranceIds {
  static const typewriter = 'typewriter';
  static const fade = 'fade';
  static const slideUp = 'slide_up';
  static const crawl = 'crawl';
  static const pop = 'pop';
  static const kinetic = 'kinetic';
  static const focus = 'focus';
  static const staged = 'staged';
  static const impact = 'impact';
  static const glitch = 'glitch';
  static const neon = 'neon';

  static const all = [
    typewriter,
    fade,
    slideUp,
    crawl,
    pop,
    kinetic,
    focus,
    staged,
    impact,
    glitch,
    neon,
  ];

  static bool isKnown(String? id) =>
      id != null && id.isNotEmpty && all.contains(id);

  /// Runs for the whole overlay duration instead of a short entrance hold.
  static bool isContinuous(String? id) => id == crawl;
}

/// Pack / overlay entrance descriptor (server-driven).
@immutable
class TextEntranceAnimation {
  const TextEntranceAnimation({
    required this.id,
    this.durationMs = defaultDurationMs,
    this.staggerOverlap = defaultStaggerOverlap,
    this.staggerBy = defaultStaggerBy,
    this.tiltDeg = defaultTiltDeg,
    this.perspective = defaultPerspective,
    this.scrollStartFactor = defaultScrollStartFactor,
    this.scrollEndFactor = defaultScrollEndFactor,
    this.bounce = defaultBounce,
    this.shake = defaultShake,
    this.scaleFrom = defaultScaleFrom,
    this.blurFrom = defaultBlurFrom,
    this.cursor = false,
    this.cursorBlinkHz = defaultCursorBlinkHz,
    this.kineticAmp = defaultKineticAmp,
    this.kineticRotDeg = defaultKineticRotDeg,
    this.slotStagger = defaultSlotStagger,
    this.glitchAmp = defaultGlitchAmp,
    this.neonFlicker = defaultNeonFlicker,
    this.punch = defaultPunch,
  });

  static const defaultDurationMs = 800;
  static const maxContinuousMs = 30000;
  static const defaultStaggerOverlap = 0.55;
  static const defaultStaggerBy = 'auto';
  static const defaultTiltDeg = 54.0;
  static const defaultPerspective = 0.0012;
  static const defaultScrollStartFactor = 14.0;
  static const defaultScrollEndFactor = -32.0;
  static const defaultBounce = 0.18;
  static const defaultShake = 0.0;
  static const defaultScaleFrom = 0.25;
  static const defaultBlurFrom = 0.35;
  static const defaultCursorBlinkHz = 2.0;
  static const defaultKineticAmp = 0.55;
  static const defaultKineticRotDeg = 12.0;
  static const defaultSlotStagger = 0.22;
  static const defaultGlitchAmp = 0.08;
  static const defaultNeonFlicker = 0.35;
  static const defaultPunch = 0.12;

  final String id;
  final int durationMs;
  final double staggerOverlap;
  final String staggerBy;
  final double tiltDeg;
  final double perspective;
  final double scrollStartFactor;
  final double scrollEndFactor;

  /// Pop / impact overshoot past 1.0 before settling.
  final double bounce;

  /// Shake amplitude as × fontSize during punch window.
  final double shake;

  /// Starting scale for pop / focus (0…1).
  final double scaleFrom;

  /// Starting blur as × fontSize for focus.
  final double blurFrom;

  /// Typewriter blinking caret after the last visible glyph.
  final bool cursor;
  final double cursorBlinkHz;

  /// Kinetic per-glyph scale excursion and rotation degrees.
  final double kineticAmp;
  final double kineticRotDeg;

  /// Staged: fraction of timeline each slot waits before the next (0…0.8).
  final double slotStagger;

  /// Glitch RGB / jitter amplitude as × fontSize.
  final double glitchAmp;

  /// Neon flicker strength during entrance (0…1).
  final double neonFlicker;

  /// Impact punch scale peak above 1.0.
  final double punch;

  double get typewriterStaggerOverlap => staggerOverlap.clamp(0.0, 0.95);

  bool typewriterStaggerByLine(String text) {
    switch (staggerBy) {
      case 'line':
        return true;
      case 'glyph':
        return false;
      default:
        return text.contains('\n');
    }
  }

  Duration get duration => Duration(
        milliseconds: durationMs.clamp(
          100,
          TextEntranceIds.isContinuous(id) ? maxContinuousMs : 10000,
        ),
      );

  bool get isNone => id.isEmpty || !TextEntranceIds.isKnown(id);

  bool get isContinuous => TextEntranceIds.isContinuous(id);

  double get flutterCrawlTiltRadians {
    final deg = tiltDeg.abs() < 0.01 ? 0.0 : tiltDeg.clamp(-80.0, 80.0);
    return -deg * math.pi / 180.0;
  }

  double get crawlPerspective => perspective.clamp(0.0002, 0.005);

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'durationMs': durationMs,
    };
    switch (id) {
      case TextEntranceIds.typewriter:
        out['staggerOverlap'] = staggerOverlap;
        out['staggerBy'] = staggerBy;
        if (cursor) {
          out['cursor'] = true;
          out['cursorBlinkHz'] = cursorBlinkHz;
        }
      case TextEntranceIds.crawl:
        out['tiltDeg'] = tiltDeg;
        out['perspective'] = perspective;
        out['scrollStartFactor'] = scrollStartFactor;
        out['scrollEndFactor'] = scrollEndFactor;
      case TextEntranceIds.pop:
        out['bounce'] = bounce;
        out['shake'] = shake;
        out['scaleFrom'] = scaleFrom;
      case TextEntranceIds.kinetic:
        out['staggerOverlap'] = staggerOverlap;
        out['kineticAmp'] = kineticAmp;
        out['kineticRotDeg'] = kineticRotDeg;
      case TextEntranceIds.focus:
        out['scaleFrom'] = scaleFrom;
        out['blurFrom'] = blurFrom;
      case TextEntranceIds.staged:
        out['slotStagger'] = slotStagger;
      case TextEntranceIds.impact:
        out['punch'] = punch;
        out['shake'] = shake;
        out['bounce'] = bounce;
      case TextEntranceIds.glitch:
        out['glitchAmp'] = glitchAmp;
      case TextEntranceIds.neon:
        out['neonFlicker'] = neonFlicker;
    }
    return out;
  }

  factory TextEntranceAnimation.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const TextEntranceAnimation(id: '');
    }
    return TextEntranceAnimation(
      id: json['id'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? defaultDurationMs,
      staggerOverlap: (json['staggerOverlap'] as num?)?.toDouble() ??
          defaultStaggerOverlap,
      staggerBy: json['staggerBy'] as String? ?? defaultStaggerBy,
      tiltDeg: (json['tiltDeg'] as num?)?.toDouble() ?? defaultTiltDeg,
      perspective:
          (json['perspective'] as num?)?.toDouble() ?? defaultPerspective,
      scrollStartFactor: (json['scrollStartFactor'] as num?)?.toDouble() ??
          defaultScrollStartFactor,
      scrollEndFactor: (json['scrollEndFactor'] as num?)?.toDouble() ??
          defaultScrollEndFactor,
      bounce: (json['bounce'] as num?)?.toDouble() ?? defaultBounce,
      shake: (json['shake'] as num?)?.toDouble() ?? defaultShake,
      scaleFrom: (json['scaleFrom'] as num?)?.toDouble() ?? defaultScaleFrom,
      blurFrom: (json['blurFrom'] as num?)?.toDouble() ?? defaultBlurFrom,
      cursor: json['cursor'] as bool? ?? false,
      cursorBlinkHz:
          (json['cursorBlinkHz'] as num?)?.toDouble() ?? defaultCursorBlinkHz,
      kineticAmp:
          (json['kineticAmp'] as num?)?.toDouble() ?? defaultKineticAmp,
      kineticRotDeg:
          (json['kineticRotDeg'] as num?)?.toDouble() ?? defaultKineticRotDeg,
      slotStagger:
          (json['slotStagger'] as num?)?.toDouble() ?? defaultSlotStagger,
      glitchAmp: (json['glitchAmp'] as num?)?.toDouble() ?? defaultGlitchAmp,
      neonFlicker:
          (json['neonFlicker'] as num?)?.toDouble() ?? defaultNeonFlicker,
      punch: (json['punch'] as num?)?.toDouble() ?? defaultPunch,
    );
  }

  TextEntranceAnimation copyWith({
    String? id,
    int? durationMs,
    double? staggerOverlap,
    String? staggerBy,
    double? tiltDeg,
    double? perspective,
    double? scrollStartFactor,
    double? scrollEndFactor,
    double? bounce,
    double? shake,
    double? scaleFrom,
    double? blurFrom,
    bool? cursor,
    double? cursorBlinkHz,
    double? kineticAmp,
    double? kineticRotDeg,
    double? slotStagger,
    double? glitchAmp,
    double? neonFlicker,
    double? punch,
  }) {
    return TextEntranceAnimation(
      id: id ?? this.id,
      durationMs: durationMs ?? this.durationMs,
      staggerOverlap: staggerOverlap ?? this.staggerOverlap,
      staggerBy: staggerBy ?? this.staggerBy,
      tiltDeg: tiltDeg ?? this.tiltDeg,
      perspective: perspective ?? this.perspective,
      scrollStartFactor: scrollStartFactor ?? this.scrollStartFactor,
      scrollEndFactor: scrollEndFactor ?? this.scrollEndFactor,
      bounce: bounce ?? this.bounce,
      shake: shake ?? this.shake,
      scaleFrom: scaleFrom ?? this.scaleFrom,
      blurFrom: blurFrom ?? this.blurFrom,
      cursor: cursor ?? this.cursor,
      cursorBlinkHz: cursorBlinkHz ?? this.cursorBlinkHz,
      kineticAmp: kineticAmp ?? this.kineticAmp,
      kineticRotDeg: kineticRotDeg ?? this.kineticRotDeg,
      slotStagger: slotStagger ?? this.slotStagger,
      glitchAmp: glitchAmp ?? this.glitchAmp,
      neonFlicker: neonFlicker ?? this.neonFlicker,
      punch: punch ?? this.punch,
    );
  }

  static const none = TextEntranceAnimation(id: '');
}

/// Resolves overlay override → pack default → none.
TextEntranceAnimation resolveOverlayAnimation(TextOverlay overlay) {
  final overrideId = overlay.animationId;
  if (overrideId != null) {
    if (overrideId.isEmpty) return TextEntranceAnimation.none;
    final pack = TextTemplatePackService.instance.itemById(overlay.packItemId);
    final packAnim = pack?.animation;
    // Keep pack geometry/params when only id/duration are overridden.
    if (packAnim != null &&
        !packAnim.isNone &&
        packAnim.id == overrideId) {
      return packAnim.copyWith(
        durationMs: overlay.animationDurationMs ?? packAnim.durationMs,
      );
    }
    return TextEntranceAnimation(
      id: overrideId,
      durationMs:
          overlay.animationDurationMs ?? TextEntranceAnimation.defaultDurationMs,
    );
  }

  final pack = TextTemplatePackService.instance.itemById(overlay.packItemId);
  final packAnim = pack?.animation;
  if (packAnim != null && !packAnim.isNone) {
    return packAnim.copyWith(
      durationMs: overlay.animationDurationMs ?? packAnim.durationMs,
    );
  }

  return TextEntranceAnimation.none;
}

Duration resolvedEntranceDuration({
  required TextOverlay overlay,
  required TextEntranceAnimation animation,
}) {
  if (animation.isNone) return Duration.zero;
  if (animation.isContinuous) {
    final span = overlay.end - overlay.start;
    if (span > Duration.zero) {
      return Duration(
        milliseconds: span.inMilliseconds.clamp(
          100,
          TextEntranceAnimation.maxContinuousMs,
        ),
      );
    }
    final fallback = overlay.animationDurationMs ?? animation.durationMs;
    return Duration(
      milliseconds: fallback.clamp(100, TextEntranceAnimation.maxContinuousMs),
    );
  }
  final overrideMs = overlay.animationDurationMs;
  if (overrideMs != null) {
    return Duration(milliseconds: overrideMs.clamp(100, 30000));
  }
  return Duration(milliseconds: animation.durationMs.clamp(100, 30000));
}

double entranceProgressAt({
  required TextOverlay overlay,
  required Duration position,
  required TextEntranceAnimation animation,
}) {
  if (animation.isNone) return 1;
  if (position < overlay.start) return 0;
  final elapsed = position - overlay.start;
  final totalMs =
      resolvedEntranceDuration(overlay: overlay, animation: animation)
          .inMilliseconds;
  if (totalMs <= 0) return 1;
  return (elapsed.inMilliseconds / totalMs).clamp(0.0, 1.0);
}

int entranceFrameIndex({
  required int elapsedMs,
  required int durationMs,
  required int frameCount,
  bool loop = false,
}) {
  if (frameCount <= 1) return 0;
  if (loop) {
    if (durationMs <= 0) return 0;
    final t = elapsedMs < 0 ? 0 : elapsedMs % durationMs;
    return (t / durationMs * frameCount).floor().clamp(0, frameCount - 1);
  }
  if (durationMs <= 0 || elapsedMs >= durationMs) return frameCount - 1;
  if (elapsedMs <= 0) return 0;
  final progress = elapsedMs / durationMs;
  return (progress * (frameCount - 1)).round().clamp(0, frameCount - 1);
}
