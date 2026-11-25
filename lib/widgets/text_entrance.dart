import 'dart:math' as math;
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Per-grapheme (or whole-layer) entrance sample for one paint frame.
@immutable
class TextEntranceGlyph {
  const TextEntranceGlyph({
    required this.opacity,
    this.dy = 0,
    this.dx = 0,
    this.scale = 1,
    this.rotation = 0,
  });

  final double opacity;
  final double dy;
  final double dx;
  final double scale;
  final double rotation;

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
    this.layerDx = 0,
    this.layerScale = 1,
    this.layerBlur = 0,
    this.layerTilt = 0,
    this.layerScroll = 0,
    this.layerPerspective = TextEntranceAnimation.defaultPerspective,
    this.rgbOffset = 0,
    this.glowPulse = 1,
    this.cursorVisible = false,
    this.slotOpacity = const [],
    this.slotDy = const [],
    this.highlightProgress = 1,
    this.perGlyph = true,
  });

  final String animationId;
  final double progress;
  final List<TextEntranceGlyph> glyphs;

  /// Karaoke: 0…1 portion of the line that uses the accent/highlight fill.
  final double highlightProgress;

  final double layerOpacity;
  final double layerDy;
  final double layerDx;
  final double layerScale;

  /// Blur sigma in logical px (focus).
  final double layerBlur;

  final double layerTilt;
  final double layerScroll;
  final double layerPerspective;

  /// Glitch RGB channel separation in logical px.
  final double rgbOffset;

  /// Neon glow intensity multiplier (0…1+).
  final double glowPulse;

  final bool cursorVisible;

  /// Staged composition: one opacity / dy per slot.
  final List<double> slotOpacity;
  final List<double> slotDy;

  final bool perGlyph;

  bool get hasCrawlTransform =>
      layerTilt.abs() > 0.001 || layerScroll.abs() > 0.5;

  bool get hasLayerTransform =>
      (layerScale - 1).abs() > 0.001 ||
      layerDx.abs() > 0.5 ||
      layerDy.abs() > 0.5 ||
      layerBlur > 0.5 ||
      rgbOffset.abs() > 0.5;

  bool get isFullyVisible =>
      progress >= 1 &&
      layerOpacity >= 0.999 &&
      layerScale >= 0.99 &&
      !hasCrawlTransform &&
      glyphs.every((g) => g.opacity >= 0.999);

  bool get isInvisible =>
      progress <= 0 ||
      (layerOpacity <= 0.01 &&
          glyphs.every((g) => !g.isVisible) &&
          (slotOpacity.isEmpty || slotOpacity.every((o) => o <= 0.01)));

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
TextEntranceState evaluateTextEntrance({
  required String? animationId,
  required String text,
  required double progress,
  double fontSize = 84,
  TextEntranceAnimation? animation,
  int? slotCount,
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

  if (id == TextEntranceIds.crawl) {
    return _crawlState(t, fontSize, animation);
  }
  if (id == TextEntranceIds.marquee) {
    return _marqueeState(t, fontSize, animation);
  }

  final anim = animation ?? TextEntranceAnimation(id: id);
  final graphemes = text.characters.toList(growable: false);
  final slots = slotCount ??
      (text.trim().isEmpty
          ? 1
          : text.split('\n').where((l) => l.trim().isNotEmpty).length);

  if (t >= 1) {
    return _holdState(
      id: id,
      anim: anim,
      graphemes: graphemes,
      slots: slots,
      fontSize: fontSize,
    );
  }
  if (t <= 0) {
    final rise = fontSize * anim.riseFactor.clamp(0.05, 1.2);
    return TextEntranceState(
      animationId: id,
      progress: 0,
      glyphs: const [],
      layerOpacity: 0,
      layerDy: fontSize * 0.35,
      layerScale: anim.scaleFrom.clamp(0.05, 1.0),
      layerBlur: fontSize * anim.blurFrom,
      slotOpacity: List<double>.filled(slots, 0),
      slotDy: List<double>.filled(slots, rise),
      perGlyph: false,
    );
  }

  if (graphemes.isEmpty && id != TextEntranceIds.staged) {
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
      return _typewriterState(t, text, graphemes, anim);
    case TextEntranceIds.fade:
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: const [],
        layerOpacity: _easeInOutCubic(t),
        perGlyph: false,
      );
    case TextEntranceIds.pop:
      return _popState(t, fontSize, anim);
    case TextEntranceIds.kinetic:
      return _kineticState(t, graphemes, fontSize, anim);
    case TextEntranceIds.focus:
      return _focusState(t, fontSize, anim);
    case TextEntranceIds.staged:
      return _stagedState(t, slots, fontSize, anim);
    case TextEntranceIds.impact:
      return _impactState(t, fontSize, anim);
    case TextEntranceIds.glitch:
      return _glitchState(t, fontSize, anim);
    case TextEntranceIds.neon:
      return _neonState(t, anim);
    case TextEntranceIds.wave:
      return _waveState(t, graphemes, fontSize, anim);
    case TextEntranceIds.blurSlide:
      return _blurSlideState(t, fontSize, anim);
    case TextEntranceIds.dissolve:
      return _dissolveState(t, graphemes, fontSize, anim);
    case TextEntranceIds.karaoke:
      return TextEntranceState(
        animationId: id,
        progress: t,
        glyphs: const [],
        layerOpacity: 1,
        highlightProgress: _easeInOutCubic(t),
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

TextEntranceState _holdState({
  required String id,
  required TextEntranceAnimation anim,
  required List<String> graphemes,
  required int slots,
  double fontSize = 24,
}) {
  final cursorOn = anim.cursor &&
      (math.sin(math.pi * 2 * anim.cursorBlinkHz * 1.0) > 0);
  switch (id) {
    case TextEntranceIds.neon:
      return TextEntranceState(
        animationId: id,
        progress: 1,
        glyphs: const [],
        layerOpacity: 1,
        glowPulse: 1,
        perGlyph: false,
      );
    case TextEntranceIds.glitch:
      return const TextEntranceState(
        animationId: TextEntranceIds.glitch,
        progress: 1,
        glyphs: [],
        layerOpacity: 1,
        rgbOffset: 0,
        perGlyph: false,
      );
    case TextEntranceIds.staged:
      return TextEntranceState(
        animationId: id,
        progress: 1,
        glyphs: const [],
        layerOpacity: 1,
        slotOpacity: List<double>.filled(math.max(1, slots), 1),
        slotDy: List<double>.filled(math.max(1, slots), 0),
        perGlyph: false,
      );
    case TextEntranceIds.typewriter:
      return TextEntranceState(
        animationId: id,
        progress: 1,
        glyphs: const [],
        layerOpacity: 1,
        cursorVisible: cursorOn,
        perGlyph: false,
      );
    case TextEntranceIds.karaoke:
      return const TextEntranceState(
        animationId: TextEntranceIds.karaoke,
        progress: 1,
        glyphs: [],
        layerOpacity: 1,
        highlightProgress: 1,
        perGlyph: false,
      );
    case TextEntranceIds.wave:
      return _waveState(1, graphemes, fontSize, anim);
    default:
      return TextEntranceState(
        animationId: id,
        progress: 1,
        glyphs: const [],
        layerOpacity: 1,
        layerScale: 1,
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

TextEntranceState _marqueeState(
  double t,
  double fontSize,
  TextEntranceAnimation? animation,
) {
  final anim = animation ??
      const TextEntranceAnimation(
        id: TextEntranceIds.marquee,
        durationMs: 8000,
        scrollStartFactor: 8,
        scrollEndFactor: -10,
      );
  final startX = fontSize * anim.scrollStartFactor;
  final endX = fontSize * anim.scrollEndFactor;
  return TextEntranceState(
    animationId: TextEntranceIds.marquee,
    progress: t,
    glyphs: const [],
    layerOpacity: 1,
    layerDx: startX + (endX - startX) * t,
    perGlyph: false,
  );
}

TextEntranceState _waveState(
  double t,
  List<String> graphemes,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final amp = fontSize * anim.kineticAmp.clamp(0.05, 0.8);
  final phaseStep = 0.55 + anim.staggerOverlap.clamp(0.0, 0.9);
  final glyphs = <TextEntranceGlyph>[];
  for (var i = 0; i < graphemes.length; i++) {
    if (graphemes[i] == '\n') {
      glyphs.add(const TextEntranceGlyph(opacity: 1));
      continue;
    }
    final dy = math.sin((t * math.pi * 2) + i * phaseStep) * amp;
    glyphs.add(TextEntranceGlyph(opacity: 1, dy: dy));
  }
  return TextEntranceState(
    animationId: TextEntranceIds.wave,
    progress: t,
    glyphs: glyphs,
    layerOpacity: 1,
    perGlyph: true,
  );
}

TextEntranceState _blurSlideState(
  double t,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final eased = _easeOutCubic(t);
  final travel = fontSize * anim.scrollStartFactor.clamp(0.8, 6.0);
  return TextEntranceState(
    animationId: TextEntranceIds.blurSlide,
    progress: t,
    glyphs: const [],
    layerOpacity: eased,
    layerDx: (1 - eased) * -travel,
    layerBlur: (1 - eased) * fontSize * anim.blurFrom.clamp(0.05, 1.2),
    perGlyph: false,
  );
}

TextEntranceState _dissolveState(
  double t,
  List<String> graphemes,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final overlap = anim.staggerOverlap.clamp(0.0, 0.9);
  final amp = fontSize * anim.kineticAmp.clamp(0.1, 1.2);
  final n = graphemes.where((g) => g != '\n').length;
  final glyphs = <TextEntranceGlyph>[];
  var gi = 0;
  for (final g in graphemes) {
    if (g == '\n') {
      glyphs.add(const TextEntranceGlyph(opacity: 1));
      continue;
    }
    final start = n <= 1 ? 0.0 : (gi / (n - 1)) * (1 - overlap);
    final local = ((t - start) / (overlap + 0.2)).clamp(0.0, 1.0);
    final scatter = 1 - _easeOutCubic(local);
    final dir = gi.isEven ? 1.0 : -1.0;
    glyphs.add(
      TextEntranceGlyph(
        opacity: local,
        dx: dir * scatter * amp,
        dy: -scatter * amp * 0.7,
        scale: 0.85 + 0.15 * local,
      ),
    );
    gi++;
  }
  return TextEntranceState(
    animationId: TextEntranceIds.dissolve,
    progress: t,
    glyphs: glyphs,
    layerOpacity: 1,
    perGlyph: true,
  );
}

TextEntranceState _typewriterState(
  double t,
  String text,
  List<String> graphemes,
  TextEntranceAnimation anim,
) {
  final overlap = anim.typewriterStaggerOverlap;
  final byLine = anim.typewriterStaggerByLine(text);
  final glyphs = byLine
      ? _staggeredByLine(
          graphemes: graphemes,
          progress: t,
          hardCut: true,
          overlap: overlap,
        )
      : _staggered(
          count: graphemes.length,
          progress: t,
          hardCut: true,
          overlap: overlap,
        );
  var cursorVisible = false;
  if (anim.cursor) {
    final visible = glyphs.where((g) => g.isVisible).length;
    final phase = (t * anim.durationMs / 1000.0) * anim.cursorBlinkHz;
    cursorVisible = visible < graphemes.length || (math.sin(phase * math.pi * 2) > 0);
  }
  return TextEntranceState(
    animationId: TextEntranceIds.typewriter,
    progress: t,
    glyphs: glyphs,
    cursorVisible: cursorVisible,
    perGlyph: true,
  );
}

TextEntranceState _popState(
  double t,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final bounce = anim.bounce.clamp(0.0, 0.6);
  final from = anim.scaleFrom.clamp(0.05, 1.0);
  // Ease to 1+bounce then settle to 1.
  final raw = _easeOutBack(t, bounce);
  final scale = from + (1 - from) * raw.clamp(0.0, 1.0 + bounce);
  final settled = t > 0.85 ? _lerp(scale, 1.0, ((t - 0.85) / 0.15).clamp(0.0, 1.0)) : scale;
  final shakeAmp = anim.shake * fontSize;
  final shake = t < 0.55 ? math.sin(t * math.pi * 10) * shakeAmp * (1 - t) : 0.0;
  return TextEntranceState(
    animationId: TextEntranceIds.pop,
    progress: t,
    glyphs: const [],
    layerOpacity: _easeOutCubic(t.clamp(0.0, 0.35) / 0.35),
    layerScale: settled.clamp(0.05, 1.0 + bounce),
    layerDx: shake,
    perGlyph: false,
  );
}

TextEntranceState _kineticState(
  double t,
  List<String> graphemes,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final overlap = anim.typewriterStaggerOverlap;
  final amp = anim.kineticAmp.clamp(0.0, 1.5);
  final rot = anim.kineticRotDeg * math.pi / 180.0;
  final base = _staggered(
    count: graphemes.length,
    progress: t,
    hardCut: false,
    overlap: overlap,
  );
  final out = <TextEntranceGlyph>[];
  for (var i = 0; i < graphemes.length; i++) {
    final g = base[i];
    if (!g.isVisible) {
      out.add(g);
      continue;
    }
    final wave = math.sin((i * 1.7) + t * math.pi * 4);
    final local = g.opacity;
    final scale = 1 + amp * (1 - local) * 0.8 + amp * 0.25 * wave * (1 - t);
    out.add(TextEntranceGlyph(
      opacity: local,
      dx: wave * fontSize * 0.08 * (1 - t),
      dy: (1 - local) * fontSize * 0.25,
      scale: scale.clamp(0.4, 2.2),
      rotation: rot * wave * (1 - local),
    ));
  }
  return TextEntranceState(
    animationId: TextEntranceIds.kinetic,
    progress: t,
    glyphs: out,
    layerOpacity: 1,
    perGlyph: true,
  );
}

TextEntranceState _focusState(
  double t,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final eased = _easeOutCubic(t);
  final from = anim.scaleFrom.clamp(0.2, 1.2);
  final scale = _lerp(from, 1.0, eased);
  final blur = fontSize * anim.blurFrom * (1 - eased);
  return TextEntranceState(
    animationId: TextEntranceIds.focus,
    progress: t,
    glyphs: const [],
    layerOpacity: eased,
    layerScale: scale,
    layerBlur: blur,
    perGlyph: false,
  );
}

TextEntranceState _stagedState(
  double t,
  int slotCount,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final n = math.max(1, slotCount);
  // Catalog-driven; previously hardcoded 0.32 / 0.4×fontSize (same as dashboard).
  final window = anim.slotWindow.clamp(0.15, 0.6);
  final rise = fontSize * anim.riseFactor.clamp(0.05, 1.2);
  // Higher slotStagger → later slots start later (more sequential).
  final span = (1.0 - window) * anim.slotStagger.clamp(0.05, 1.0);
  final opacities = <double>[];
  final dys = <double>[];
  for (var i = 0; i < n; i++) {
    final start = n == 1 ? 0.0 : (i / (n - 1)) * span;
    final local = ((t - start) / window).clamp(0.0, 1.0);
    // Ease-out cubic: fast rise, slow settle (dashboard parity).
    final eased = _easeOutCubic(local);
    opacities.add(eased);
    dys.add((1 - eased) * rise);
  }
  return TextEntranceState(
    animationId: TextEntranceIds.staged,
    progress: t,
    glyphs: const [],
    layerOpacity: 1,
    slotOpacity: opacities,
    slotDy: dys,
    perGlyph: false,
  );
}

TextEntranceState _impactState(
  double t,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final eased = _easeOutCubic((t / 0.45).clamp(0.0, 1.0));
  final punch = anim.punch.clamp(0.0, 0.5);
  double scale = 1;
  if (t < 0.35) {
    scale = _lerp(anim.scaleFrom.clamp(0.4, 1.0), 1 + punch, eased);
  } else if (t < 0.55) {
    scale = _lerp(1 + punch, 1.0, ((t - 0.35) / 0.2).clamp(0.0, 1.0));
  }
  final shakeAmp = anim.shake * fontSize;
  final shake = t < 0.5 ? math.sin(t * math.pi * 16) * shakeAmp * (1 - t * 2) : 0.0;
  return TextEntranceState(
    animationId: TextEntranceIds.impact,
    progress: t,
    glyphs: const [],
    layerOpacity: eased,
    layerScale: scale,
    layerDx: shake,
    layerDy: (1 - eased) * fontSize * -0.15,
    perGlyph: false,
  );
}

TextEntranceState _glitchState(
  double t,
  double fontSize,
  TextEntranceAnimation anim,
) {
  final amp = anim.glitchAmp * fontSize;
  final burst = t < 0.75;
  final wave = math.sin(t * math.pi * 18) * (burst ? 1 : (1 - t) * 4);
  final opacity = t < 0.1 ? t / 0.1 : 1.0;
  return TextEntranceState(
    animationId: TextEntranceIds.glitch,
    progress: t,
    glyphs: const [],
    layerOpacity: opacity.clamp(0.0, 1.0),
    layerDx: wave * amp * 0.4,
    rgbOffset: burst ? amp * (0.6 + 0.4 * wave.abs()) : amp * (1 - t) * 0.5,
    perGlyph: false,
  );
}

TextEntranceState _neonState(double t, TextEntranceAnimation anim) {
  final flicker = anim.neonFlicker.clamp(0.0, 1.0);
  final ramp = _easeOutCubic(t);
  final noise = 0.5 + 0.5 * math.sin(t * math.pi * 14);
  final pulse = ramp * (1 - flicker * 0.5 + flicker * 0.5 * noise);
  return TextEntranceState(
    animationId: TextEntranceIds.neon,
    progress: t,
    glyphs: const [],
    layerOpacity: ramp.clamp(0.15, 1.0),
    glowPulse: pulse.clamp(0.2, 1.35),
    perGlyph: false,
  );
}

List<TextEntranceGlyph> _staggered({
  required int count,
  required double progress,
  required bool hardCut,
  double overlap = TextEntranceAnimation.defaultStaggerOverlap,
}) {
  if (count <= 0) return const [];
  final o = overlap.clamp(0.0, 0.95);
  final slot = 1 / (count + (count - 1) * o);
  final step = slot * (1 + o);
  final window = slot * (1 + o * 0.5);
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

List<TextEntranceGlyph> _staggeredByLine({
  required List<String> graphemes,
  required double progress,
  required bool hardCut,
  required double overlap,
}) {
  if (graphemes.isEmpty) return const [];
  final lines = <List<int>>[];
  var current = <int>[];
  for (var i = 0; i < graphemes.length; i++) {
    current.add(i);
    if (graphemes[i] == '\n') {
      lines.add(current);
      current = <int>[];
    }
  }
  if (current.isNotEmpty) lines.add(current);

  final out = List<TextEntranceGlyph>.filled(
    graphemes.length,
    const TextEntranceGlyph(opacity: 0),
    growable: false,
  );
  if (lines.isEmpty) return out;

  final lineCount = lines.length;
  final scaled = progress.clamp(0.0, 1.0) * lineCount;
  final active = scaled.floor().clamp(0, lineCount - 1);
  final localT = (scaled - active).clamp(0.0, 1.0);

  for (var li = 0; li < lineCount; li++) {
    final idxs = lines[li];
    if (li < active) {
      for (final i in idxs) {
        out[i] = const TextEntranceGlyph(opacity: 1);
      }
      continue;
    }
    if (li > active) continue;
    final content = [
      for (final i in idxs)
        if (graphemes[i] != '\n') i,
    ];
    if (content.isEmpty) {
      for (final i in idxs) {
        out[i] = const TextEntranceGlyph(opacity: 1);
      }
      continue;
    }
    final inner = _staggered(
      count: content.length,
      progress: localT,
      hardCut: hardCut,
      overlap: overlap,
    );
    for (var k = 0; k < content.length; k++) {
      out[content[k]] = inner[k];
    }
    for (final i in idxs) {
      if (graphemes[i] == '\n') {
        out[i] = const TextEntranceGlyph(opacity: 1);
      }
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

/// Overshoot ease; [overshoot] ~0.18 matches CSS back easing feel.
double _easeOutBack(double t, double overshoot) {
  final c1 = 1.70158 * (1 + overshoot * 2);
  final c3 = c1 + 1;
  final u = t - 1;
  return 1 + c3 * u * u * u + c1 * u * u;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
