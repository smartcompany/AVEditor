import 'dart:math' as math;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/foundation.dart';

/// Built-in entrance / continuous motion ids the client knows how to paint/export.
abstract final class TextEntranceIds {
  static const typewriter = 'typewriter';
  static const fade = 'fade';
  static const slideUp = 'slide_up';
  /// Perspective scroll over the full overlay span (Star Wars-style crawl).
  static const crawl = 'crawl';

  static const all = [typewriter, fade, slideUp, crawl];

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
    this.tiltDeg = defaultTiltDeg,
    this.perspective = defaultPerspective,
    this.scrollStartFactor = defaultScrollStartFactor,
    this.scrollEndFactor = defaultScrollEndFactor,
  });

  static const defaultDurationMs = 800;

  /// Suggested crawl / entrance length when the overlay span is unknown.
  static const maxContinuousMs = 30000;

  /// Classic crawl tilt magnitude in degrees (bottom nearer). Flutter applies
  /// the Y-down sign in [flutterCrawlTiltRadians].
  static const defaultTiltDeg = 54.0;
  static const defaultPerspective = 0.0012;
  static const defaultScrollStartFactor = 14.0;
  static const defaultScrollEndFactor = -32.0;

  final String id;
  final int durationMs;

  /// Server-driven crawl tilt in degrees (positive = Star Wars direction).
  final double tiltDeg;

  /// Server-driven perspective strength for [Matrix4.setEntry] / CSS.
  final double perspective;

  /// Start translateY as a multiple of font size (positive = below frame).
  final double scrollStartFactor;

  /// End translateY as a multiple of font size (negative = into distance).
  final double scrollEndFactor;

  Duration get duration => Duration(
        milliseconds: durationMs.clamp(
          100,
          TextEntranceIds.isContinuous(id) ? maxContinuousMs : 10000,
        ),
      );

  bool get isNone => id.isEmpty || !TextEntranceIds.isKnown(id);

  bool get isContinuous => TextEntranceIds.isContinuous(id);

  /// Flutter canvas is Y-down: negate so positive [tiltDeg] matches CSS/dashboard.
  /// 0° is a flat credits scroll; clamp only the magnitude when non-zero.
  double get flutterCrawlTiltRadians {
    final deg = tiltDeg.abs() < 0.01 ? 0.0 : tiltDeg.clamp(-80.0, 80.0);
    return -deg * math.pi / 180.0;
  }

  double get crawlPerspective =>
      perspective.clamp(0.0002, 0.005);

  Map<String, dynamic> toJson() => {
        'id': id,
        'durationMs': durationMs,
        if (TextEntranceIds.isContinuous(id)) ...{
          'tiltDeg': tiltDeg,
          'perspective': perspective,
          'scrollStartFactor': scrollStartFactor,
          'scrollEndFactor': scrollEndFactor,
        },
      };

  factory TextEntranceAnimation.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const TextEntranceAnimation(id: '');
    }
    return TextEntranceAnimation(
      id: json['id'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? defaultDurationMs,
      tiltDeg: (json['tiltDeg'] as num?)?.toDouble() ?? defaultTiltDeg,
      perspective:
          (json['perspective'] as num?)?.toDouble() ?? defaultPerspective,
      scrollStartFactor: (json['scrollStartFactor'] as num?)?.toDouble() ??
          defaultScrollStartFactor,
      scrollEndFactor: (json['scrollEndFactor'] as num?)?.toDouble() ??
          defaultScrollEndFactor,
    );
  }

  TextEntranceAnimation copyWith({
    String? id,
    int? durationMs,
    double? tiltDeg,
    double? perspective,
    double? scrollStartFactor,
    double? scrollEndFactor,
  }) {
    return TextEntranceAnimation(
      id: id ?? this.id,
      durationMs: durationMs ?? this.durationMs,
      tiltDeg: tiltDeg ?? this.tiltDeg,
      perspective: perspective ?? this.perspective,
      scrollStartFactor: scrollStartFactor ?? this.scrollStartFactor,
      scrollEndFactor: scrollEndFactor ?? this.scrollEndFactor,
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
    // Keep crawl geometry from the pack when only id/duration are overridden.
    if (packAnim != null &&
        !packAnim.isNone &&
        packAnim.id == overrideId &&
        TextEntranceIds.isContinuous(overrideId)) {
      return packAnim.copyWith(
        durationMs:
            overlay.animationDurationMs ?? packAnim.durationMs,
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

/// How long the motion plays before the finished look holds.
///
/// Continuous crawl uses the overlay span (capped). Short entrances use
/// pack/catalog [TextEntranceAnimation.durationMs] (or an override).
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

/// Progress 0..1 from playhead relative to overlay start.
///
/// Clamps at 1 so short entrances hold the finished look; crawl stays at the
/// end pose for any remainder past the capped span.
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

/// PNG index for [elapsedMs] since the overlay's own start.
///
/// Same clock as [entranceProgressAt]: 0 is the first entrance frame, and
/// once the entrance ends the last frame holds. Clip boundaries do not reset it.
///
/// When [loop] is true (sticker GIFs), frames cycle for the whole span using
/// [durationMs] as one loop length.
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
