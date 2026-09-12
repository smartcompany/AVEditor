import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/widgets/transition_layer_runtime.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Composites any outgoing/incoming layers with the same preview styles used
/// for live video and picker A→B thumbnails.
///
/// Prefer catalog [TransitionItem.layers] when present (server-driven). Named
/// style fallbacks cover classic xfade names without layer authoring.
class TransitionAbCompositor extends StatelessWidget {
  const TransitionAbCompositor({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.t,
    required this.plan,
  });

  final Widget outgoing;
  final Widget incoming;

  /// 0 at transition start (fully A), 1 at end (fully B).
  final double t;
  final TransitionRenderPlan plan;

  @override
  Widget build(BuildContext context) {
    final progress = t.clamp(0.0, 1.0);
    final layers = plan.definition?.layers ?? const [];
    // Primitive effects are fully server-authored via layers. Classic xfade
    // names keep the built-in style map (wipes/iris/etc.).
    if (plan.renderer == TransitionRendererKind.primitive &&
        layers.isNotEmpty &&
        plan.previewKind != TransitionPreviewKind.none) {
      final definition = plan.definition!;
      return TransitionLayerCompositor(
        outgoing: outgoing,
        incoming: incoming,
        t: progress,
        layers: layers,
        parameters: {
          ...definition.defaultParameters(),
          ...plan.applied.parameters,
        },
      );
    }

    final style = resolvePreviewStyle(plan);
    final intensity = _intensity(plan.applied);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return switch (style) {
          TransitionPreviewStyle.fade => _fade(progress),
          TransitionPreviewStyle.dissolve => _fade(progress),
          TransitionPreviewStyle.dipBlack =>
            _dip(progress, Colors.black, intensity),
          TransitionPreviewStyle.dipWhite =>
            _dip(progress, Colors.white, intensity),
          TransitionPreviewStyle.flash => _flash(progress, intensity),
          TransitionPreviewStyle.slideLeft =>
            _slide(progress, size, const Offset(-1, 0)),
          TransitionPreviewStyle.slideRight =>
            _slide(progress, size, const Offset(1, 0)),
          TransitionPreviewStyle.slideUp =>
            _slide(progress, size, const Offset(0, -1)),
          TransitionPreviewStyle.slideDown =>
            _slide(progress, size, const Offset(0, 1)),
          TransitionPreviewStyle.pushLeft =>
            _push(progress, size, const Offset(-1, 0)),
          TransitionPreviewStyle.pushRight =>
            _push(progress, size, const Offset(1, 0)),
          TransitionPreviewStyle.pushUp =>
            _push(progress, size, const Offset(0, -1)),
          TransitionPreviewStyle.pushDown =>
            _push(progress, size, const Offset(0, 1)),
          TransitionPreviewStyle.wipeLeft =>
            _wipe(progress, Alignment.centerLeft, Axis.horizontal),
          TransitionPreviewStyle.wipeRight =>
            _wipe(progress, Alignment.centerRight, Axis.horizontal),
          TransitionPreviewStyle.wipeUp =>
            _wipe(progress, Alignment.topCenter, Axis.vertical),
          TransitionPreviewStyle.wipeDown =>
            _wipe(progress, Alignment.bottomCenter, Axis.vertical),
          TransitionPreviewStyle.zoomIn => _zoomIn(progress, intensity),
          TransitionPreviewStyle.zoomOut => _zoomOut(progress, intensity),
          TransitionPreviewStyle.crossZoom => _crossZoom(progress, intensity),
          TransitionPreviewStyle.zoomBlur => _zoomBlur(progress, intensity),
          TransitionPreviewStyle.iris => _iris(progress),
          TransitionPreviewStyle.irisClose => _iris(1 - progress),
          TransitionPreviewStyle.radial => _iris(progress),
          TransitionPreviewStyle.none => outgoing,
        };
      },
    );
  }

  Widget _fade(double t) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: outgoing),
        Opacity(opacity: t, child: incoming),
      ],
    );
  }

  Widget _dip(double t, Color color, double intensity) {
    final peak = (1 - (2 * t - 1).abs()).clamp(0.0, 1.0) * intensity;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: outgoing),
        Opacity(opacity: t, child: incoming),
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
        Opacity(opacity: 1 - t, child: outgoing),
        Opacity(opacity: t, child: incoming),
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
          child: outgoing,
        ),
        Transform.translate(
          offset: Offset(dx * (t - 1), dy * (t - 1)),
          child: incoming,
        ),
      ],
    );
  }

  Widget _push(double t, Size size, Offset dir) {
    final dx = dir.dx * size.width;
    final dy = dir.dy * size.height;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Transform.translate(
          offset: Offset(dx * t, dy * t),
          child: outgoing,
        ),
        Transform.translate(
          offset: Offset(dx * (t - 1), dy * (t - 1)),
          child: incoming,
        ),
      ],
    );
  }

  Widget _wipe(double t, Alignment growFrom, Axis axis) {
    return Stack(
      fit: StackFit.expand,
      children: [
        outgoing,
        ClipRect(
          clipper: _WipeClipper(t: t, growFrom: growFrom, axis: axis),
          child: incoming,
        ),
      ],
    );
  }

  Widget _zoomIn(double t, double intensity) {
    final scale = 1.0 + 0.35 * intensity * (1 - t);
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - t, child: outgoing),
        Opacity(
          opacity: t,
          child: Transform.scale(
            scale: scale,
            child: incoming,
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
          child: Transform.scale(scale: scale, child: outgoing),
        ),
        Opacity(opacity: t, child: incoming),
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
          child: Transform.scale(scale: outScale, child: outgoing),
        ),
        Opacity(
          opacity: t,
          child: Transform.scale(scale: inScale, child: incoming),
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
            Transform.scale(scale: scale, child: outgoing),
          ),
        ),
        Opacity(
          opacity: t,
          child: blurLayer(
            Transform.scale(scale: 1.2 - 0.2 * t, child: incoming),
          ),
        ),
      ],
    );
  }

  Widget _iris(double t) {
    return Stack(
      fit: StackFit.expand,
      children: [
        outgoing,
        ClipPath(
          clipper: _IrisClipper(t: t),
          child: incoming,
        ),
      ],
    );
  }

  static double _intensity(AppliedTransition applied) {
    final value = applied.parameters['intensity'];
    if (value == null) return 0.75;
    return value.clamp(0.0, 1.0);
  }
}

/// Maps a render plan to a dual-layer preview style.
TransitionPreviewStyle resolvePreviewStyle(TransitionRenderPlan plan) {
  if (plan.previewKind == TransitionPreviewKind.none) {
    return TransitionPreviewStyle.none;
  }

  final id = plan.applied.id.toLowerCase();
  final name = (plan.xfadeName ?? id).toLowerCase();
  final token = '$id $name';

  if (token.contains('flash')) return TransitionPreviewStyle.flash;
  if (token.contains('fadeblack') ||
      (token.contains('dip') && token.contains('black'))) {
    return TransitionPreviewStyle.dipBlack;
  }
  if (token.contains('fadewhite') ||
      (token.contains('dip') && token.contains('white'))) {
    return TransitionPreviewStyle.dipWhite;
  }
  if (token.contains('zoomblur') || name == 'hblur') {
    return TransitionPreviewStyle.zoomBlur;
  }
  if (token.contains('crosszoom')) return TransitionPreviewStyle.crossZoom;
  if (token.contains('zoomout') || name == 'squeezev' || name == 'squeezeh') {
    return TransitionPreviewStyle.zoomOut;
  }
  if (token.contains('zoomin') || name == 'zoomin') {
    return TransitionPreviewStyle.zoomIn;
  }

  if (token.contains('pushleft') || name == 'coverleft') {
    return TransitionPreviewStyle.pushLeft;
  }
  if (token.contains('pushright') || name == 'coverright') {
    return TransitionPreviewStyle.pushRight;
  }
  if (token.contains('pushup') || name == 'coverup') {
    return TransitionPreviewStyle.pushUp;
  }
  if (token.contains('pushdown') || name == 'coverdown') {
    return TransitionPreviewStyle.pushDown;
  }

  if (token.contains('slideleft') || name == 'slideleft') {
    return TransitionPreviewStyle.slideLeft;
  }
  if (token.contains('slideright') || name == 'slideright') {
    return TransitionPreviewStyle.slideRight;
  }
  if (token.contains('slideup') || name == 'slideup') {
    return TransitionPreviewStyle.slideUp;
  }
  if (token.contains('slidedown') || name == 'slidedown') {
    return TransitionPreviewStyle.slideDown;
  }

  if (token.contains('wipeleft') || name == 'wipeleft') {
    return TransitionPreviewStyle.wipeLeft;
  }
  if (token.contains('wiperight') || name == 'wiperight') {
    return TransitionPreviewStyle.wipeRight;
  }
  if (token.contains('wipeup') || name == 'wipeup') {
    return TransitionPreviewStyle.wipeUp;
  }
  if (token.contains('wipedown') || name == 'wipedown') {
    return TransitionPreviewStyle.wipeDown;
  }

  if (token.contains('circleclose') || name == 'circleclose') {
    return TransitionPreviewStyle.irisClose;
  }
  if (token.contains('circle') || token.contains('iris') || name == 'radial') {
    return token.contains('radial')
        ? TransitionPreviewStyle.radial
        : TransitionPreviewStyle.iris;
  }

  if (token.contains('dissolve')) return TransitionPreviewStyle.dissolve;
  return TransitionPreviewStyle.fade;
}

enum TransitionPreviewStyle {
  none,
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
  irisClose,
  radial,
}

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
    Widget layer(VideoPlayerController controller, {required bool isIncoming}) {
      return SizedBox.expand(
        child: VideoPlayer(
          controller,
          key: isIncoming ? incomingPlayerKey : outgoingPlayerKey,
        ),
      );
    }

    return TransitionAbCompositor(
      outgoing: layer(outgoing, isIncoming: false),
      incoming: layer(incoming, isIncoming: true),
      t: t,
      plan: plan,
    );
  }
}

/// Keeps both physical decoder views in a fixed Stack order so transition
/// handoff only changes opacities/transforms — never remounts/reparents the
/// visible [VideoPlayer] (the classic last-frame jump).
class StableDualSlotPreview extends StatelessWidget {
  const StableDualSlotPreview({
    super.key,
    required this.slotMain,
    required this.slotAux,
    required this.slotsSwapped,
    this.t,
    this.plan,
  });

  final Widget slotMain;
  final Widget slotAux;
  final bool slotsSwapped;

  /// Null when idle (show logical primary only).
  final double? t;
  final TransitionRenderPlan? plan;

  static const _identity = TransitionLayerPose();
  static const _hidden = TransitionLayerPose(opacity: 0);

  @override
  Widget build(BuildContext context) {
    final progress = t;
    final activePlan = plan;

    TransitionLayerPose mainPose;
    TransitionLayerPose auxPose;
    var useRoleCompositor = false;

    if (progress == null || activePlan == null) {
      mainPose = slotsSwapped ? _hidden : _identity;
      auxPose = slotsSwapped ? _identity : _hidden;
    } else {
      final layers = activePlan.definition?.layers ?? const [];
      if (layers.isNotEmpty) {
        final eval = evaluateTransitionLayers(
          layers: layers,
          t: progress,
          parameters: {
            ...activePlan.definition!.defaultParameters(),
            ...activePlan.applied.parameters,
          },
        );
        mainPose = slotsSwapped ? eval.incoming : eval.outgoing;
        auxPose = slotsSwapped ? eval.outgoing : eval.incoming;
      } else {
        final style = resolvePreviewStyle(activePlan);
        if (_needsRoleCompositor(style)) {
          useRoleCompositor = true;
          mainPose = _identity;
          auxPose = _identity;
        } else {
          final eval = _posesForStyle(
            style,
            progress,
            _intensity(activePlan.applied),
          );
          mainPose = slotsSwapped ? eval.incoming : eval.outgoing;
          auxPose = slotsSwapped ? eval.outgoing : eval.incoming;
        }
      }
    }

    if (useRoleCompositor && progress != null && activePlan != null) {
      final outgoing = slotsSwapped ? slotAux : slotMain;
      final incoming = slotsSwapped ? slotMain : slotAux;
      return TransitionAbCompositor(
        outgoing: SizedBox.expand(child: outgoing),
        incoming: SizedBox.expand(child: incoming),
        t: progress,
        plan: activePlan,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            posedTransitionLayer(mainPose, size, slotMain),
            posedTransitionLayer(auxPose, size, slotAux),
          ],
        );
      },
    );
  }

  static bool _needsRoleCompositor(TransitionPreviewStyle style) {
    return switch (style) {
      TransitionPreviewStyle.wipeLeft ||
      TransitionPreviewStyle.wipeRight ||
      TransitionPreviewStyle.wipeUp ||
      TransitionPreviewStyle.wipeDown ||
      TransitionPreviewStyle.iris ||
      TransitionPreviewStyle.irisClose ||
      TransitionPreviewStyle.radial =>
        true,
      _ => false,
    };
  }

  static TransitionLayerEvaluation _posesForStyle(
    TransitionPreviewStyle style,
    double t,
    double intensity,
  ) {
    final progress = t.clamp(0.0, 1.0);
    switch (style) {
      case TransitionPreviewStyle.none:
        return const TransitionLayerEvaluation(
          outgoing: _identity,
          incoming: _hidden,
        );
      case TransitionPreviewStyle.fade:
      case TransitionPreviewStyle.dissolve:
      case TransitionPreviewStyle.dipBlack:
      case TransitionPreviewStyle.dipWhite:
      case TransitionPreviewStyle.flash:
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(opacity: 1 - progress),
          incoming: TransitionLayerPose(opacity: progress),
        );
      case TransitionPreviewStyle.slideLeft:
        return _slidePoses(progress, const Offset(-1, 0));
      case TransitionPreviewStyle.slideRight:
        return _slidePoses(progress, const Offset(1, 0));
      case TransitionPreviewStyle.slideUp:
        return _slidePoses(progress, const Offset(0, -1));
      case TransitionPreviewStyle.slideDown:
        return _slidePoses(progress, const Offset(0, 1));
      case TransitionPreviewStyle.pushLeft:
        return _slidePoses(progress, const Offset(-1, 0));
      case TransitionPreviewStyle.pushRight:
        return _slidePoses(progress, const Offset(1, 0));
      case TransitionPreviewStyle.pushUp:
        return _slidePoses(progress, const Offset(0, -1));
      case TransitionPreviewStyle.pushDown:
        return _slidePoses(progress, const Offset(0, 1));
      case TransitionPreviewStyle.zoomIn:
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(opacity: 1 - progress),
          incoming: TransitionLayerPose(
            opacity: progress,
            scale: 1.0 + 0.35 * intensity * (1 - progress),
          ),
        );
      case TransitionPreviewStyle.zoomOut:
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(
            opacity: 1 - progress,
            scale: 1.0 + 0.35 * intensity * progress,
          ),
          incoming: TransitionLayerPose(opacity: progress),
        );
      case TransitionPreviewStyle.crossZoom:
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(
            opacity: 1 - progress,
            scale: 1.0 + 0.25 * intensity * progress,
          ),
          incoming: TransitionLayerPose(
            opacity: progress,
            scale: 1.0 + 0.25 * intensity * (1 - progress),
          ),
        );
      case TransitionPreviewStyle.zoomBlur:
        final blur = 8.0 * intensity * math.sin(progress * math.pi);
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(
            opacity: 1 - progress,
            scale: 1.0 + 0.2 * intensity * progress,
            blur: blur,
          ),
          incoming: TransitionLayerPose(
            opacity: progress,
            scale: 1.2 - 0.2 * progress,
            blur: blur,
          ),
        );
      case TransitionPreviewStyle.wipeLeft:
      case TransitionPreviewStyle.wipeRight:
      case TransitionPreviewStyle.wipeUp:
      case TransitionPreviewStyle.wipeDown:
      case TransitionPreviewStyle.iris:
      case TransitionPreviewStyle.irisClose:
      case TransitionPreviewStyle.radial:
        return TransitionLayerEvaluation(
          outgoing: TransitionLayerPose(opacity: 1 - progress),
          incoming: TransitionLayerPose(opacity: progress),
        );
    }
  }

  static TransitionLayerEvaluation _slidePoses(double t, Offset dir) {
    return TransitionLayerEvaluation(
      outgoing: TransitionLayerPose(
        translateX: dir.dx * t,
        translateY: dir.dy * t,
      ),
      incoming: TransitionLayerPose(
        translateX: dir.dx * (t - 1),
        translateY: dir.dy * (t - 1),
      ),
    );
  }

  static double _intensity(AppliedTransition applied) {
    final value = applied.parameters['intensity'];
    if (value == null) return 0.75;
    return value.clamp(0.0, 1.0);
  }
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
    return Path()..addOval(Rect.fromCircle(center: center, radius: maxR * t));
  }

  @override
  bool shouldReclip(covariant _IrisClipper oldClipper) => oldClipper.t != t;
}
