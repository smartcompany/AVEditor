import 'dart:math' as math;
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Per-grapheme (or whole-layer) entrance sample for one paint frame.
@immutable
class TextEntranceGlyph {
  const TextEntranceGlyph({required this.opacity, this.dy = 0});

  final double opacity;
  final double dy;

  bool get isVisible => opacity > 0.01;
}

@immutable
class TextEntranceState {
  const TextEntranceState({
    required this.animationId,
    required this.progress,
    required this.glyphs,
    this.layerOpacity = 1,
    this.layerDy = 0,
    this.layerTilt = 0,
    this.layerScroll = 0,
    this.layerPerspective = TextEntranceAnimation.defaultPerspective,
    this.perGlyph = true,
  });

  final String animationId;
  final double progress;
  final List<TextEntranceGlyph> glyphs;

  /// Whole-layer fade / slide (used by [TextEntranceIds.slideUp]).
  final double layerOpacity;
  final double layerDy;

  /// Continuous crawl: rotateX radians + vertical scroll in logical px.
  final double layerTilt;
  final double layerScroll;

  /// Crawl perspective strength ([Matrix4.setEntry] 3,2).
  final double layerPerspective;
  final bool perGlyph;

  bool get hasCrawlTransform =>
      layerTilt.abs() > 0.001 || layerScroll.abs() > 0.5;

  bool get isFullyVisible =>
      progress >= 1 &&
      layerOpacity >= 0.999 &&
      !hasCrawlTransform &&
      glyphs.every((g) => g.opacity >= 0.999);

  bool get isInvisible =>
      progress <= 0 ||
      (layerOpacity <= 0.01 && glyphs.every((g) => !g.isVisible));

  static const fullyVisible = TextEntranceState(
    animationId: '',
    progress: 1,
    glyphs: [],
    layerOpacity: 1,
    layerDy: 0,
    layerTilt: 0,
    layerScroll: 0,
    perGlyph: false,
  );
}

/// Evaluates entrance / continuous motion for [text] at [progress] (0..1).
///
/// Pass [animation] so server-driven crawl geometry (tilt / perspective /
/// scroll factors) is applied; [animationId] alone still works with defaults.
TextEntranceState evaluateTextEntrance({
  required String? animationId,
  required String text,
  required double progress,
  double fontSize = 84,
  TextEntranceAnimation? animation,
}) {
  final t = progress.clamp(0.0, 1.0);
  final id = animation?.id.isNotEmpty == true
      ? animation!.id
      : (animationId ?? '');
  if (!TextEntranceIds.isKnown(id)) {
    return TextEntranceState(
      animationId: id,
      progress: 1,
      glyphs: const [],
      layerOpacity: 1,
      layerDy: 0,
      perGlyph: false,
    );
  }

  // Continuous crawl keeps its end pose at t == 1 (tilted + scrolled away).
  if (id == TextEntranceIds.crawl) {
    return _crawlState(t, fontSize, animation);
  }

  if (t >= 1) {
    return TextEntranceState(
      animationId: id,
      progress: 1,
      glyphs: const [],
      layerOpacity: 1,
      layerDy: 0,
      perGlyph: false,
    );
  }
  if (t <= 0) {
    return TextEntranceState(
      animationId: id,
      progress: 0,
      glyphs: const [],
      layerOpacity: 0,
      layerDy: fontSize * 0.35,
      perGlyph: false,
    );
  }

  final graphemes = text.characters.toList(growable: false);
  if (graphemes.isEmpty) {
    return TextEntranceState(
      animationId: id,
      progress: t,
      glyphs: const [],
      layerOpacity: t,
      perGlyph: false,
    );
  }

  switch (id) {
    case TextEntranceIds.slideUp:
      final eased = _easeOutCubic(t);
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: const [],
        layerOpacity: eased,
        layerDy: (1 - eased) * fontSize * 0.45,
        perGlyph: false,
      );
    case TextEntranceIds.typewriter:
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: _staggered(count: graphemes.length, progress: t, hardCut: true),
        perGlyph: true,
      );
    case TextEntranceIds.fade:
      // Whole line fades in together. A per-glyph stagger read as a soft
      // typewriter, so fade and typewriter looked the same.
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: const [],
        layerOpacity: _easeInOutCubic(t),
        perGlyph: false,
      );
    default:
      return TextEntranceState(
        animationId: id,
        progress: 1,
        glyphs: const [],
        perGlyph: false,
      );
  }
}

TextEntranceState _crawlState(
  double t,
  double fontSize,
  TextEntranceAnimation? animation,
) {
  final anim = animation ??
      const TextEntranceAnimation(
        id: TextEntranceIds.crawl,
        durationMs: 18000,
      );
  // Scroll runs from below the frame toward the vanishing point at the top.
  // Tilt / perspective / travel come from the server catalog when present.
  final startY = fontSize * anim.scrollStartFactor;
  final endY = fontSize * anim.scrollEndFactor;
  final scroll = startY + (endY - startY) * t;
  return TextEntranceState(
    animationId: TextEntranceIds.crawl,
    progress: t,
    glyphs: const [],
    layerOpacity: 1,
    layerDy: 0,
    layerTilt: anim.flutterCrawlTiltRadians,
    layerScroll: scroll,
    layerPerspective: anim.crawlPerspective,
    perGlyph: false,
  );
}

List<TextEntranceGlyph> _staggered({
  required int count,
  required double progress,
  required bool hardCut,
}) {
  if (count <= 0) return const [];
  const overlap = 0.55;
  final slot = 1 / (count + (count - 1) * overlap);
  final step = slot * (1 + overlap);
  final window = slot * (1 + overlap * 0.5);
  final out = <TextEntranceGlyph>[];
  for (var i = 0; i < count; i++) {
    final start = i * step;
    if (progress < start) {
      out.add(const TextEntranceGlyph(opacity: 0));
      continue;
    }
    if (progress >= start + window) {
      out.add(const TextEntranceGlyph(opacity: 1));
      continue;
    }
    final local = ((progress - start) / window).clamp(0.0, 1.0);
    if (hardCut) {
      out.add(TextEntranceGlyph(opacity: local > 0.15 ? 1 : 0));
    } else {
      out.add(TextEntranceGlyph(opacity: _easeOutCubic(local)));
    }
  }
  return out;
}

double _easeOutCubic(double t) {
  final u = 1 - t;
  return 1 - u * u * u;
}

double _easeInOutCubic(double t) {
  if (t < 0.5) return 4 * t * t * t;
  return 1 - math.pow(-2 * t + 2, 3) / 2;
}
