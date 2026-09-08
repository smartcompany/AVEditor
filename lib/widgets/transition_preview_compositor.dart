import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Live dual-player approximation of a catalog transition for the editor
/// preview. Export still uses FFmpeg; this keeps the top video looking like
/// the selected effect while scrubbing / playing through a cut.
class TransitionPreviewCompositor extends StatelessWidget {
  const TransitionPreviewCompositor({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.t,
    required this.plan,
    this.outgoingPlayerKey,
    this.incomingPlayerKey,
  });

  final VideoPlayerController outgoing;
  final VideoPlayerController incoming;

  /// 0 at fade/cut window start, 1 at outgoing.end.
  final double t;
  final TransitionRenderPlan plan;
  final Key? outgoingPlayerKey;
  final Key? incomingPlayerKey;

  @override
  Widget build(BuildContext context) {
    final progress = t.clamp(0.0, 1.0);
    final style = _resolveStyle(plan);
    final intensity = _intensity(plan.applied);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return switch (style) {
          _PreviewStyle.fade => _fade(progress),
          _PreviewStyle.dissolve => _fade(progress),
          _PreviewStyle.dipBlack => _dip(progress, Colors.black, intensity),
          _PreviewStyle.dipWhite => _dip(progress, Colors.white, intensity),
          _PreviewStyle.flash => _flash(progress, intensity),
          _PreviewStyle.slideLeft =>
            _slide(progress, size, const Offset(-1, 0)),
          _PreviewStyle.slideRight =>
            _slide(progress, size, const Offset(1, 0)),
          _PreviewStyle.slideUp => _slide(progress, size, const Offset(0, -1)),
          _PreviewStyle.slideDown => _slide(progress, size, const Offset(0, 1)),
          _PreviewStyle.pushLeft =>
            _push(progress, size, const Offset(-1, 0)),
          _PreviewStyle.pushRight =>
            _push(progress, size, const Offset(1, 0)),
          _PreviewStyle.pushUp => _push(progress, size, const Offset(0, -1)),
          _PreviewStyle.pushDown => _push(progress, size, const Offset(0, 1)),
          _PreviewStyle.wipeLeft =>
            _wipe(progress, Alignment.centerLeft, Axis.horizontal),
          _PreviewStyle.wipeRight =>
            _wipe(progress, Alignment.centerRight, Axis.horizontal),
          _PreviewStyle.wipeUp =>
            _wipe(progress, Alignment.topCenter, Axis.vertical),
          _PreviewStyle.wipeDown =>
            _wipe(progress, Alignment.bottomCenter, Axis.vertical),
          _PreviewStyle.zoomIn => _zoomIn(progress, intensity),
          _PreviewStyle.zoomOut => _zoomOut(progress, intensity),
          _PreviewStyle.crossZoom => _crossZoom(progress, intensity),
          _PreviewStyle.zoomBlur => _zoomBlur(progress, intensity),
          _PreviewStyle.iris => _iris(progress),
          _PreviewStyle.radial => _iris(progress),
        };
      },
    );
  }

  Widget _layer(VideoPlayerController controller, {required bool incoming}) {
    return SizedBox.expand(
      child: VideoPlayer(
        controller,
        key: incoming ? incomingPlayerKey : outgoingPlayerKey,
      ),
    );
  }

  Widget _out() => _layer(outgoing, incoming: false);
  Widget _in() => _layer(incoming, incoming: true);

  Widget _fade(double t) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: _out()),
        Opacity(opacity: t, child: _in()),
      ],
    );
  }

  Widget _dip(double t, Color color, double intensity) {
    final peak = (1 - (2 * t - 1).abs()).clamp(0.0, 1.0) * intensity;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: _out()),
        Opacity(opacity: t, child: _in()),
        IgnorePointer(
          child: ColoredBox(color: color.withValues(alpha: peak)),
        ),
      ],
    );
  }

  Widget _flash(double t, double intensity) {
    final flash = math.sin(t * math.pi).clamp(0.0, 1.0) * intensity;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: _out()),
        Opacity(opacity: t, child: _in()),
        IgnorePointer(
          child: ColoredBox(color: Colors.white.withValues(alpha: flash)),
        ),
      ],
    );
  }

  Widget _slide(double t, Size size, Offset dir) {
    final dx = dir.dx * size.width;
    final dy = dir.dy * size.height;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Transform.translate(
          offset: Offset(dx * t, dy * t),
          child: _out(),
        ),
        Transform.translate(
          offset: Offset(dx * (t - 1), dy * (t - 1)),
          child: _in(),
        ),
      ],
    );
  }

  Widget _push(double t, Size size, Offset dir) {
    // Incoming pushes outgoing out (cover-style).
    final dx = dir.dx * size.width;
    final dy = dir.dy * size.height;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Transform.translate(
          offset: Offset(dx * t, dy * t),
          child: _out(),
        ),
        Transform.translate(
          offset: Offset(dx * (t - 1), dy * (t - 1)),
          child: _in(),
        ),
      ],
    );
  }

  Widget _wipe(double t, Alignment growFrom, Axis axis) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _out(),
        ClipRect(
          clipper: _WipeClipper(t: t, growFrom: growFrom, axis: axis),
          child: _in(),
        ),
      ],
    );
  }

  Widget _zoomIn(double t, double intensity) {
    final scale = 1.0 + 0.35 * intensity * (1 - t);
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: _out()),
        Opacity(
          opacity: t,
          child: Transform.scale(
            scale: scale,
            child: _in(),
          ),
        ),
      ],
    );
  }

  Widget _zoomOut(double t, double intensity) {
    final scale = 1.0 + 0.35 * intensity * t;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: 1 - t,
          child: Transform.scale(scale: scale, child: _out()),
        ),
        Opacity(opacity: t, child: _in()),
      ],
    );
  }

  Widget _crossZoom(double t, double intensity) {
    final outScale = 1.0 + 0.25 * intensity * t;
    final inScale = 1.0 + 0.25 * intensity * (1 - t);
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: 1 - t,
          child: Transform.scale(scale: outScale, child: _out()),
        ),
        Opacity(
          opacity: t,
          child: Transform.scale(scale: inScale, child: _in()),
        ),
      ],
    );
  }

  Widget _zoomBlur(double t, double intensity) {
    final blur = 8.0 * intensity * math.sin(t * math.pi);
    final scale = 1.0 + 0.2 * intensity * t;
    Widget blurLayer(Widget child) {
      if (blur < 0.3) return child;
      return ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: child,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: 1 - t,
          child: blurLayer(
            Transform.scale(scale: scale, child: _out()),
          ),
        ),
        Opacity(
          opacity: t,
          child: blurLayer(
            Transform.scale(scale: 1.2 - 0.2 * t, child: _in()),
          ),
        ),
      ],
    );
  }

  Widget _iris(double t) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _out(),
        ClipPath(
          clipper: _IrisClipper(t: t),
          child: _in(),
        ),
      ],
    );
  }

  static double _intensity(AppliedTransition applied) {
    final value = applied.parameters['intensity'];
    if (value == null) return 0.75;
    return value.clamp(0.0, 1.0);
  }

  static _PreviewStyle _resolveStyle(TransitionRenderPlan plan) {
    final id = plan.applied.id.toLowerCase();
    final name = (plan.xfadeName ?? id).toLowerCase();
    final token = '$id $name';

    if (token.contains('flash')) return _PreviewStyle.flash;
    if (token.contains('fadeblack') ||
        (token.contains('dip') && token.contains('black'))) {
      return _PreviewStyle.dipBlack;
    }
    if (token.contains('fadewhite') ||
        (token.contains('dip') && token.contains('white'))) {
      return _PreviewStyle.dipWhite;
    }
    if (token.contains('zoomblur') || name == 'hblur') {
      return _PreviewStyle.zoomBlur;
    }
    if (token.contains('crosszoom')) return _PreviewStyle.crossZoom;
    if (token.contains('zoomout') || name == 'squeezev' || name == 'squeezeh') {
      return _PreviewStyle.zoomOut;
    }
    if (token.contains('zoomin') || name == 'zoomin') return _PreviewStyle.zoomIn;

    if (token.contains('pushleft') || name == 'coverleft') {
      return _PreviewStyle.pushLeft;
    }
    if (token.contains('pushright') || name == 'coverright') {
      return _PreviewStyle.pushRight;
    }
    if (token.contains('pushup') || name == 'coverup') return _PreviewStyle.pushUp;
    if (token.contains('pushdown') || name == 'coverdown') {
      return _PreviewStyle.pushDown;
    }

    if (token.contains('slideleft') || name == 'slideleft') {
      return _PreviewStyle.slideLeft;
    }
    if (token.contains('slideright') || name == 'slideright') {
      return _PreviewStyle.slideRight;
    }
    if (token.contains('slideup') || name == 'slideup') return _PreviewStyle.slideUp;
    if (token.contains('slidedown') || name == 'slidedown') {
      return _PreviewStyle.slideDown;
    }

    if (token.contains('wipeleft') || name == 'wipeleft') {
      return _PreviewStyle.wipeLeft;
    }
    if (token.contains('wiperight') || name == 'wiperight') {
      return _PreviewStyle.wipeRight;
    }
    if (token.contains('wipeup') || name == 'wipeup') return _PreviewStyle.wipeUp;
    if (token.contains('wipedown') || name == 'wipedown') {
      return _PreviewStyle.wipeDown;
    }

    if (token.contains('circle') || token.contains('iris') || name == 'radial') {
      return token.contains('radial') ? _PreviewStyle.radial : _PreviewStyle.iris;
    }

    if (token.contains('dissolve')) return _PreviewStyle.dissolve;
    return _PreviewStyle.fade;
  }
}

enum _PreviewStyle {
  fade,
  dissolve,
  dipBlack,
  dipWhite,
  flash,
  slideLeft,
  slideRight,
  slideUp,
  slideDown,
  pushLeft,
  pushRight,
  pushUp,
  pushDown,
  wipeLeft,
  wipeRight,
  wipeUp,
  wipeDown,
  zoomIn,
  zoomOut,
  crossZoom,
  zoomBlur,
  iris,
  radial,
}

class _WipeClipper extends CustomClipper<Rect> {
  _WipeClipper({
    required this.t,
    required this.growFrom,
    required this.axis,
  });

  final double t;
  final Alignment growFrom;
  final Axis axis;

  @override
  Rect getClip(Size size) {
    if (axis == Axis.horizontal) {
      final w = size.width * t;
      if (growFrom == Alignment.centerLeft) {
        return Rect.fromLTWH(0, 0, w, size.height);
      }
      return Rect.fromLTWH(size.width - w, 0, w, size.height);
    }
    final h = size.height * t;
    if (growFrom == Alignment.topCenter) {
      return Rect.fromLTWH(0, 0, size.width, h);
    }
    return Rect.fromLTWH(0, size.height - h, size.width, h);
  }

  @override
  bool shouldReclip(covariant _WipeClipper oldClipper) =>
      oldClipper.t != t ||
      oldClipper.growFrom != growFrom ||
      oldClipper.axis != axis;
}

class _IrisClipper extends CustomClipper<Path> {
  _IrisClipper({required this.t});

  final double t;

  @override
  Path getClip(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.sqrt(
      size.width * size.width + size.height * size.height,
    ) /
        2;
    return Path()
      ..addOval(Rect.fromCircle(center: center, radius: maxR * t));
  }

  @override
  bool shouldReclip(covariant _IrisClipper oldClipper) => oldClipper.t != t;
}
