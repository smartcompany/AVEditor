import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Per-grapheme (or whole-layer) entrance sample for one paint frame.
@immutable
class TextEntranceGlyph {
  const TextEntranceGlyph({
    required this.opacity,
    this.dy = 0,
  });

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
    this.perGlyph = true,
  });

  final String animationId;
  final double progress;
  final List<TextEntranceGlyph> glyphs;

  /// Whole-layer fade / slide (used by [TextEntranceIds.slideUp]).
  final double layerOpacity;
  final double layerDy;
  final bool perGlyph;

  bool get isFullyVisible =>
      progress >= 1 && layerOpacity >= 0.999 && glyphs.every((g) => g.opacity >= 0.999);

  bool get isInvisible =>
      progress <= 0 || (layerOpacity <= 0.01 && glyphs.every((g) => !g.isVisible));

  static const fullyVisible = TextEntranceState(
    animationId: '',
    progress: 1,
    glyphs: [],
    layerOpacity: 1,
    layerDy: 0,
    perGlyph: false,
  );
}

/// Evaluates entrance motion for [text] at [progress] (0..1).
TextEntranceState evaluateTextEntrance({
  required String? animationId,
  required String text,
  required double progress,
  double fontSize = 84,
}) {
  final t = progress.clamp(0.0, 1.0);
  final id = animationId ?? '';
  if (!TextEntranceIds.isKnown(id) || t >= 1) {
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
        glyphs: _staggered(
          count: graphemes.length,
          progress: t,
          hardCut: true,
        ),
        perGlyph: true,
      );
    case TextEntranceIds.fade:
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: _staggered(
          count: graphemes.length,
          progress: t,
          hardCut: false,
        ),
        perGlyph: true,
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

List<TextEntranceGlyph> _staggered({
  required int count,
  required double progress,
  required bool hardCut,
}) {
  if (count <= 0) return const [];
  // Each glyph gets a window; overlap so motion feels continuous.
  const overlap = 0.55;
  final slot = 1.0 / (count + (count - 1) * overlap);
  final step = slot * (1 + overlap);
  return [
    for (var i = 0; i < count; i++)
      TextEntranceGlyph(
        opacity: _glyphOpacity(
          progress: progress,
          start: i * step,
          window: slot * (1 + overlap * 0.5),
          hardCut: hardCut,
        ),
      ),
  ];
}

double _glyphOpacity({
  required double progress,
  required double start,
  required double window,
  required bool hardCut,
}) {
  if (progress < start) return 0;
  if (progress >= start + window) return 1;
  final local = ((progress - start) / window).clamp(0.0, 1.0);
  if (hardCut) return local > 0.15 ? 1 : 0;
  return _easeOutCubic(local);
}

double _easeOutCubic(double t) {
  final u = 1 - t;
  return 1 - u * u * u;
}
