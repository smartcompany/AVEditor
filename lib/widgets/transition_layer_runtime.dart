import 'dart:math' as math;
import 'dart:ui' as ui show ImageFilter;

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Evaluates catalog [TransitionLayer]s at progress `t` into per-clip poses.
///
/// New transition looks should be authored in the server catalog; this runtime
/// is the fixed client surface (opacity / transform / blur / brightness).
class TransitionLayerPose {
  const TransitionLayerPose({
    this.opacity = 1,
    this.scale = 1,
    this.translateX = 0,
    this.translateY = 0,
    this.rotation = 0,
    this.rotationY = 0,
    this.ripple = 0,
    this.blur = 0,
    this.brightness = 0,
    this.blurMode,
    this.wipe = 0,
    this.wipeEdge = 'left',
  });

  final double opacity;
  final double scale;
  /// Frame-normalized (-1 = full width left, 1 = full width right).
  final double translateX;
  final double translateY;
  /// Turns (1.0 = 360°) around Z.
  final double rotation;
  /// Turns around Y. 0.5 shows the other clip.
  final double rotationY;
  /// Concentric wave progress. 0 = A, 1 = B after the wave.
  final double ripple;
  final double blur;
  /// -1…1 style lift used as a white/black overlay.
  final double brightness;
  /// Server hint for blur rendering (`zoom` = radial streaks).
  final String? blurMode;
  /// 0 = full clip, 1 = fully wiped away.
  final double wipe;
  /// Edge erased first for [wipe].
  final String wipeEdge;

  TransitionLayerPose copyWith({
    double? opacity,
    double? scale,
    double? translateX,
    double? translateY,
    double? rotation,
    double? rotationY,
    double? ripple,
    double? blur,
    double? brightness,
    String? blurMode,
    double? wipe,
    String? wipeEdge,
  }) {
    return TransitionLayerPose(
      opacity: opacity ?? this.opacity,
      scale: scale ?? this.scale,
      translateX: translateX ?? this.translateX,
      translateY: translateY ?? this.translateY,
      rotation: rotation ?? this.rotation,
      rotationY: rotationY ?? this.rotationY,
      ripple: ripple ?? this.ripple,
      blur: blur ?? this.blur,
      brightness: brightness ?? this.brightness,
      blurMode: blurMode ?? this.blurMode,
      wipe: wipe ?? this.wipe,
      wipeEdge: wipeEdge ?? this.wipeEdge,
    );
  }
}

class TransitionLayerEvaluation {
  const TransitionLayerEvaluation({
    required this.a,
    required this.b,
  });

  final TransitionLayerPose a;
  final TransitionLayerPose b;
}

/// Pure evaluation of catalog layers — no Flutter widgets.
TransitionLayerEvaluation evaluateTransitionLayers({
  required List<TransitionLayer> layers,
  required double t,
  Map<String, double> parameters = const {},
}) {
  final progress = t.clamp(0.0, 1.0);
  final frameLayers = layers.where((layer) => layer.grid == null).toList();
  if (frameLayers.isEmpty && layers.any((layer) => layer.grid != null)) {
    return const TransitionLayerEvaluation(
      a: TransitionLayerPose(),
      b: TransitionLayerPose(),
    );
  }
  var a = const TransitionLayerPose(opacity: 1);
  var b = const TransitionLayerPose(opacity: 0);

  final hasOpacity =
      frameLayers.any((l) => l.property == TransitionProperty.opacity);
  var aOpacitySet = false;
  var bOpacitySet = false;

  for (final layer in frameLayers) {
    // Windowed layers must not apply their `from` before [start] — that would
    // stomp earlier writers (e.g. fade-to-black's second brightness track
    // holding -1 for the whole first half).
    final windowStart = layer.start.clamp(0.0, 1.0);
    if (progress < windowStart) continue;

    final value = evaluateTransitionLayer(
      layer,
      progress,
      parameters: parameters,
    );
    if (layer.target == TransitionLayerTarget.a ||
        layer.target == TransitionLayerTarget.both) {
      a = _applyProperty(a, layer, value);
      if (layer.property == TransitionProperty.opacity) {
        aOpacitySet = true;
      }
    }
    if (layer.target == TransitionLayerTarget.b ||
        layer.target == TransitionLayerTarget.both) {
      b = _applyProperty(b, layer, value);
      if (layer.property == TransitionProperty.opacity) {
        bOpacitySet = true;
      }
    }
  }

  if (!hasOpacity) {
    // Spatial motion (slide/push) should stay solid — auto crossfade makes
    // the two clips ghost through each other and looks unnatural.
    final spatial = frameLayers.any(
      (l) =>
          l.property == TransitionProperty.translateX ||
          l.property == TransitionProperty.translateY ||
          l.property == TransitionProperty.rotation ||
          l.property == TransitionProperty.rotationY ||
          l.property == TransitionProperty.ripple ||
          l.property == TransitionProperty.wipe,
    );
    if (spatial) {
      a = a.copyWith(opacity: 1);
      b = b.copyWith(opacity: 1);
    } else {
      a = a.copyWith(opacity: 1 - progress);
      b = b.copyWith(opacity: progress);
    }
  } else if (aOpacitySet && !bOpacitySet) {
    b = b.copyWith(opacity: (1 - a.opacity).clamp(0.0, 1.0));
  } else if (bOpacitySet && !aOpacitySet) {
    a = a.copyWith(opacity: (1 - b.opacity).clamp(0.0, 1.0));
  }

  return TransitionLayerEvaluation(a: a, b: b);
}

/// Applies [layers] at [t] onto [base] without the opacity auto-fill.
TransitionLayerEvaluation applyTransitionLayers({
  required TransitionLayerEvaluation base,
  required List<TransitionLayer> layers,
  required double t,
  Map<String, double> parameters = const {},
}) {
  final progress = t.clamp(0.0, 1.0);
  var a = base.a;
  var b = base.b;
  for (final layer in layers) {
    if (progress < layer.start.clamp(0.0, 1.0)) continue;
    final value = evaluateTransitionLayer(
      layer,
      progress,
      parameters: parameters,
    );
    if (layer.target == TransitionLayerTarget.a ||
        layer.target == TransitionLayerTarget.both) {
      a = _applyProperty(a, layer, value);
    }
    if (layer.target == TransitionLayerTarget.b ||
        layer.target == TransitionLayerTarget.both) {
      b = _applyProperty(b, layer, value);
    }
  }
  return TransitionLayerEvaluation(a: a, b: b);
}

/// Cell-local progress. [stagger] is the share of the timeline used as delay.
///
/// Phase is a golden-ratio scramble so neighboring cells do not move together.
/// Same formula in the dashboard and the iOS exporter.
double gridCellProgress(int index, double t, double stagger) {
  final progress = t.clamp(0.0, 1.0);
  final spread = stagger.clamp(0.0, 0.95);
  if (spread <= 0.0001) return progress;
  final phase = (index * 0.618033988749895) % 1.0;
  final start = phase * spread;
  return ((progress - start) / (1.0 - spread)).clamp(0.0, 1.0);
}

/// One cell: base layers use global [t], gridded layers use [gridCellProgress].
TransitionLayerEvaluation evaluateGridCell(
  List<TransitionLayer> layers,
  double t,
  int index, {
  Map<String, double> parameters = const {},
}) {
  final gridLayers = layers.where((layer) => layer.grid != null).toList();
  final cellLayers = gridLayers.isEmpty
      ? layers
          .where((layer) => layer.property == TransitionProperty.rotationY)
          .toList()
      : gridLayers;
  final baseLayers =
      layers.where((layer) => !cellLayers.contains(layer)).toList();
  var evaluation = baseLayers.isEmpty
      ? const TransitionLayerEvaluation(
          a: TransitionLayerPose(),
          b: TransitionLayerPose(),
        )
      : evaluateTransitionLayers(
          layers: baseLayers,
          t: t,
          parameters: parameters,
        );
  for (final layer in cellLayers) {
    evaluation = applyTransitionLayers(
      base: evaluation,
      layers: [layer],
      t: gridCellProgress(index, t, layer.grid?.stagger ?? 0),
      parameters: parameters,
    );
  }
  return evaluation;
}

/// Visible Y-rotation. Past 90° the other clip faces the camera.
({bool showBack, double faceRadians}) rotationYFace(double turns) {
  final angle = turns * math.pi * 2;
  final showBack = math.cos(angle) < 0;
  final face = showBack
      ? (angle > 0 ? angle - math.pi : angle + math.pi)
      : angle;
  return (showBack: showBack, faceRadians: face);
}

double evaluateTransitionLayer(
  TransitionLayer layer,
  double t, {
  Map<String, double> parameters = const {},
}) {
  final start = layer.start.clamp(0.0, 1.0);
  final end = layer.end < start ? start : layer.end.clamp(0.0, 1.0);
  final from = _resolveEndpoint(layer.from, layer, parameters);
  final to = _resolveEndpoint(layer.to, layer, parameters);

  if (t <= start) return from;
  if (t >= end || end <= start) return to;

  final local = ((t - start) / (end - start)).clamp(0.0, 1.0);
  final u = _ease(layer.easing, local, layer.bezier);
  return from + (to - from) * u;
}

double _resolveEndpoint(
  double authored,
  TransitionLayer layer,
  Map<String, double> parameters,
) {
  final key = layer.param;
  if (key == null || key.isEmpty) return authored;
  final raw = parameters[key];
  final amount = (raw ?? 1.0).clamp(0.0, 1.0);
  final identity = _identity(layer.property);
  return identity + (authored - identity) * amount;
}

double _identity(TransitionProperty property) {
  switch (property) {
    case TransitionProperty.opacity:
    case TransitionProperty.scale:
      return 1;
    case TransitionProperty.translateX:
    case TransitionProperty.translateY:
    case TransitionProperty.rotation:
    case TransitionProperty.rotationY:
    case TransitionProperty.ripple:
    case TransitionProperty.blur:
    case TransitionProperty.brightness:
    case TransitionProperty.saturation:
    case TransitionProperty.contrast:
    case TransitionProperty.wipe:
      return 0;
  }
}

TransitionLayerPose _applyProperty(
  TransitionLayerPose pose,
  TransitionLayer layer,
  double value,
) {
  switch (layer.property) {
    case TransitionProperty.opacity:
      return pose.copyWith(opacity: value.clamp(0.0, 1.0));
    case TransitionProperty.scale:
      return pose.copyWith(scale: value);
    case TransitionProperty.translateX:
      return pose.copyWith(translateX: value);
    case TransitionProperty.translateY:
      return pose.copyWith(translateY: value);
    case TransitionProperty.rotation:
      return pose.copyWith(rotation: value);
    case TransitionProperty.rotationY:
      return pose.copyWith(rotationY: value);
    case TransitionProperty.ripple:
      return pose.copyWith(ripple: value.clamp(0.0, 1.0));
    case TransitionProperty.blur:
      return pose.copyWith(blur: value, blurMode: layer.mode);
    case TransitionProperty.brightness:
      return pose.copyWith(brightness: value);
    case TransitionProperty.wipe:
      return pose.copyWith(
        wipe: value.clamp(0.0, 1.0),
        wipeEdge: (layer.mode ?? pose.wipeEdge).toLowerCase(),
      );
    case TransitionProperty.saturation:
    case TransitionProperty.contrast:
      // Not approximated in the dual-layer preview yet.
      return pose;
  }
}

double _ease(TransitionEasing easing, double t, List<double>? bezier) {
  switch (easing) {
    case TransitionEasing.linear:
      return t;
    case TransitionEasing.easeIn:
      return Curves.easeIn.transform(t);
    case TransitionEasing.easeOut:
      return Curves.easeOut.transform(t);
    case TransitionEasing.easeInOut:
      return Curves.easeInOut.transform(t);
    case TransitionEasing.cubic:
      return Curves.ease.transform(t);
    case TransitionEasing.bounce:
      return Curves.bounceOut.transform(t);
    case TransitionEasing.elastic:
      return Curves.elasticOut.transform(t);
    case TransitionEasing.cubicBezier:
      if (bezier != null && bezier.length >= 4) {
        return Cubic(bezier[0], bezier[1], bezier[2], bezier[3]).transform(t);
      }
      return Curves.easeInOut.transform(t);
  }
}

/// Applies catalog layers to outgoing/incoming widgets (picker + live preview).
class TransitionLayerCompositor extends StatelessWidget {
  const TransitionLayerCompositor({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.t,
    required this.layers,
    this.parameters = const {},
  });

  final Widget outgoing;
  final Widget incoming;
  final double t;
  final List<TransitionLayer> layers;
  final Map<String, double> parameters;

  @override
  Widget build(BuildContext context) {
    if (layers.any((layer) => layer.property == TransitionProperty.ripple)) {
      return _RippleLayer(
        progress: t.clamp(0.0, 1.0),
        layers: layers,
        parameters: parameters,
        outgoing: outgoing,
        incoming: incoming,
      );
    }
    if (layers.any((layer) => layer.grid != null) ||
        layers.any((layer) => layer.property == TransitionProperty.rotationY)) {
      return _GridLayer(
        progress: t.clamp(0.0, 1.0),
        layers: layers,
        parameters: parameters,
        outgoing: outgoing,
        incoming: incoming,
      );
    }
    final eval = evaluateTransitionLayers(
      layers: layers,
      t: t,
      parameters: parameters,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Always keep both layers mounted. Dropping a VideoPlayer when opacity
        // hits 0 forces a remount/reparent at handoff and flashes the last frame.
        if (isConveyorSlidePose(eval.a, eval.b)) {
          return conveyorSlideLayer(
            size: size,
            outgoing: eval.a,
            incoming: eval.b,
            outgoingChild: outgoing,
            incomingChild: incoming,
          );
        }
        final veil = _sharedBrightnessVeil(eval);
        final outgoingOnTop = aShouldPaintOnTop(eval, layers: layers);
        final bottomPose = outgoingOnTop ? eval.b : eval.a;
        final topPose = outgoingOnTop ? eval.a : eval.b;
        final bottomChild = outgoingOnTop ? incoming : outgoing;
        final topChild = outgoingOnTop ? outgoing : incoming;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            posedTransitionLayer(
              veil != null ? _poseWithoutBrightness(bottomPose) : bottomPose,
              size,
              bottomChild,
            ),
            posedTransitionLayer(
              veil != null ? _poseWithoutBrightness(topPose) : topPose,
              size,
              topChild,
            ),
            // Shared veil so dip-to-black/white isn't diluted by per-clip opacity.
            if (veil != null) IgnorePointer(child: ColoredBox(color: veil)),
          ],
        );
      },
    );
  }
}

TransitionLayerPose _poseWithoutBrightness(TransitionLayerPose pose) {
  if (pose.brightness.abs() < 0.001) return pose;
  return pose.copyWith(brightness: 0);
}

bool _isActivelyTransformed(TransitionLayerPose pose) {
  return pose.rotation.abs() > 0.001 ||
      pose.rotationY.abs() > 0.001 ||
      (pose.scale - 1).abs() > 0.01 ||
      pose.translateX.abs() > 0.01 ||
      pose.translateY.abs() > 0.01 ||
      pose.wipe > 0.001;
}

/// Paint order from catalog: last layer with `target` A or B is on top
/// (`both` does not change order). Authors put the mover last; optional
/// identity layers on the other clip document the backdrop.
///
/// Fall back to live pose thresholds when only style-derived poses are available.
bool aShouldPaintOnTop(
  TransitionLayerEvaluation eval, {
  List<TransitionLayer> layers = const [],
}) {
  if (layers.isNotEmpty) {
    TransitionLayerTarget? top;
    for (final layer in layers) {
      if (layer.target == TransitionLayerTarget.a ||
          layer.target == TransitionLayerTarget.b) {
        top = layer.target;
      }
    }
    if (top == null) return false;
    return top == TransitionLayerTarget.a;
  }
  return _isActivelyTransformed(eval.a) && !_isActivelyTransformed(eval.b);
}

/// When both sides share the same brightness (dip), paint one fullscreen veil.
Color? _sharedBrightnessVeil(TransitionLayerEvaluation eval) {
  final a = eval.a.brightness;
  final b = eval.b.brightness;
  if (a.abs() < 0.001 && b.abs() < 0.001) return null;
  // Same-signed dip authored on `both` — one overlay above the crossfade.
  if ((a - b).abs() < 0.02 && a.sign == b.sign) {
    final amount = a.abs().clamp(0.0, 1.0);
    final base = a >= 0 ? Colors.white : Colors.black;
    return base.withValues(alpha: amount);
  }
  return null;
}

/// Applies a catalog pose to a child (shared by picker + live dual-slot preview).
Widget posedTransitionLayer(TransitionLayerPose pose, Size size, Widget child) {
  Widget built = child;
  if (pose.blur.abs() > 0.3) {
    if (pose.blurMode == 'zoom') {
      // Approximate radial zoom streaks: stacked scaled copies + soft blur.
      final amount = (pose.blur.abs() / 18.0).clamp(0.0, 1.0);
      final source = built;
      built = Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 3; i >= 1; i--)
            Opacity(
              opacity: 0.18 * amount,
              child: Transform.scale(
                scale: 1.0 + amount * 0.12 * i,
                child: source,
              ),
            ),
          source,
        ],
      );
      built = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: pose.blur.abs() * 0.35,
          sigmaY: pose.blur.abs() * 0.35,
        ),
        child: built,
      );
    } else {
      built = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: pose.blur.abs(),
          sigmaY: pose.blur.abs(),
        ),
        child: built,
      );
    }
  }
  // Pixel-snap translation. Sub-pixel Flutter transforms on platform
  // [VideoPlayer] views shimmer left/right every frame (esp. long slides).
  final dx = (pose.translateX * size.width).roundToDouble();
  final dy = (pose.translateY * size.height).roundToDouble();
  final needsTransform =
      dx != 0 || dy != 0 || pose.rotation != 0 || (pose.scale - 1).abs() > 0.0001;
  if (needsTransform) {
    built = Transform(
      alignment: Alignment.center,
      filterQuality: FilterQuality.none,
      transform: Matrix4.identity()
        ..translateByDouble(dx, dy, 0, 1)
        ..rotateZ(pose.rotation * math.pi * 2)
        ..scaleByDouble(pose.scale, pose.scale, 1, 1),
      child: built,
    );
  }
  if (pose.wipe > 0.001 && pose.wipe < 0.999) {
    built = ClipRect(
      clipper: _PoseWipeClipper(wipe: pose.wipe, edge: pose.wipeEdge),
      child: built,
    );
  } else if (pose.wipe >= 0.999) {
    built = const SizedBox.shrink();
  }
  if (pose.brightness.abs() > 0.001) {
    final overlay = pose.brightness >= 0 ? Colors.white : Colors.black;
    built = Stack(
      fit: StackFit.expand,
      children: [
        built,
        IgnorePointer(
          child: ColoredBox(
            color: overlay.withValues(
              alpha: pose.brightness.abs().clamp(0.0, 1.0),
            ),
          ),
        ),
      ],
    );
  }
  // Opacity on a platform video view also jitters — skip when fully opaque.
  if (pose.opacity < 0.999) {
    built = Opacity(
      opacity: pose.opacity.clamp(0.0, 1.0),
      child: built,
    );
  }
  return built;
}

/// True when A/B are adjacent conveyor frames (slide/push), not a free transform.
bool isConveyorSlidePose(TransitionLayerPose outgoing, TransitionLayerPose incoming) {
  final dx = incoming.translateX - outgoing.translateX;
  final dy = incoming.translateY - outgoing.translateY;
  final horizontal = (dx.abs() - 1).abs() < 0.03 && dy.abs() < 0.03;
  final vertical = (dy.abs() - 1).abs() < 0.03 && dx.abs() < 0.03;
  if (!horizontal && !vertical) return false;
  // Both should stay fully opaque for a solid slide.
  return outgoing.opacity > 0.98 && incoming.opacity > 0.98;
}

/// One shared translate for both clips — avoids dual platform-view transforms
/// fighting each other (the left/right tremble on long Slide Left previews).
Widget conveyorSlideLayer({
  required Size size,
  required TransitionLayerPose outgoing,
  required TransitionLayerPose incoming,
  required Widget outgoingChild,
  required Widget incomingChild,
}) {
  final w = size.width;
  final h = size.height;
  final horizontal =
      (incoming.translateX - outgoing.translateX).abs() >
      (incoming.translateY - outgoing.translateY).abs();

  // Stack + Positioned only — never Row/Column (those report RenderFlex
  // overflow even when the strip is intentionally wider than the viewport).
  if (horizontal) {
    final outIsLeft = outgoing.translateX <= incoming.translateX;
    final leftChild = outIsLeft ? outgoingChild : incomingChild;
    final rightChild = outIsLeft ? incomingChild : outgoingChild;
    final leftPose = outIsLeft ? outgoing : incoming;
    final shiftX = (leftPose.translateX * w).roundToDouble();
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: shiftX,
            top: 0,
            width: w,
            height: h,
            child: leftChild,
          ),
          Positioned(
            left: shiftX + w,
            top: 0,
            width: w,
            height: h,
            child: rightChild,
          ),
        ],
      ),
    );
  }

  final outIsTop = outgoing.translateY <= incoming.translateY;
  final topChild = outIsTop ? outgoingChild : incomingChild;
  final bottomChild = outIsTop ? incomingChild : outgoingChild;
  final topPose = outIsTop ? outgoing : incoming;
  final shiftY = (topPose.translateY * h).roundToDouble();
  return ClipRect(
    child: Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: 0,
          top: shiftY,
          width: w,
          height: h,
          child: topChild,
        ),
        Positioned(
          left: 0,
          top: shiftY + h,
          width: w,
          height: h,
          child: bottomChild,
        ),
      ],
    ),
  );
}

/// Clip remaining region for wipe on A (or any pose). [wipe] 0=full, 1=gone;
/// [edge] is the side erased first.
class _PoseWipeClipper extends CustomClipper<Rect> {
  _PoseWipeClipper({required this.wipe, required this.edge});

  final double wipe;
  final String edge;

  @override
  Rect getClip(Size size) {
    final w = wipe.clamp(0.0, 1.0);
    final remain = 1.0 - w;
    switch (edge) {
      case 'right':
        return Rect.fromLTWH(0, 0, size.width * remain, size.height);
      case 'top':
        return Rect.fromLTWH(0, size.height * w, size.width, size.height * remain);
      case 'bottom':
        return Rect.fromLTWH(0, 0, size.width, size.height * remain);
      case 'left':
      default:
        return Rect.fromLTWH(size.width * w, 0, size.width * remain, size.height);
    }
  }

  @override
  bool shouldReclip(covariant _PoseWipeClipper oldClipper) =>
      oldClipper.wipe != wipe || oldClipper.edge != edge;
}

/// Progressive reveal of B over static A — prefer catalog `wipe` layers on A.
/// Kept for legacy `effect.kind: wipe` previews.
Widget wipeTransitionLayer({
  required Size size,
  required double t,
  required Widget outgoing,
  required Widget incoming,
  String edge = 'left',
}) {
  final progress = t.clamp(0.0, 1.0);
  final Alignment growFrom;
  final Axis axis;
  switch (edge) {
    case 'right':
      growFrom = Alignment.centerRight;
      axis = Axis.horizontal;
    case 'top':
      growFrom = Alignment.topCenter;
      axis = Axis.vertical;
    case 'bottom':
      growFrom = Alignment.bottomCenter;
      axis = Axis.vertical;
    case 'left':
    default:
      growFrom = Alignment.centerLeft;
      axis = Axis.horizontal;
  }
  return Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.hardEdge,
    children: [
      outgoing,
      ClipRect(
        clipper: _WipeEdgeClipper(
          t: progress,
          growFrom: growFrom,
          axis: axis,
        ),
        child: incoming,
      ),
    ],
  );
}

class _WipeEdgeClipper extends CustomClipper<Rect> {
  _WipeEdgeClipper({
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
  bool shouldReclip(covariant _WipeEdgeClipper oldClipper) =>
      oldClipper.t != t ||
      oldClipper.growFrom != growFrom ||
      oldClipper.axis != axis;
}

/// A splits from the center into L/R doors; B advances through the opening.
///
/// Uses a single outgoing child (safe for [VideoPlayer]) clipped to the two
/// door bands as they retreat to the frame edges. Scale endpoints come from
/// the server `effect` map — not hardcoded catalog ids.
Widget doorwayTransitionLayer({
  required Size size,
  required double t,
  required Widget outgoing,
  required Widget incoming,
  double incomingScaleFrom = 0.84,
  double incomingScaleTo = 1.0,
}) {
  final u = Curves.easeInOutCubic.transform(t.clamp(0.0, 1.0));
  final from = incomingScaleFrom;
  final to = incomingScaleTo;
  final bScale = from + (to - from) * Curves.easeOutCubic.transform(u);

  return Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.hardEdge,
    children: [
      Transform.scale(
        scale: bScale,
        filterQuality: FilterQuality.low,
        child: incoming,
      ),
      ClipPath(
        clipper: _DoorwayDoorsClipper(progress: u),
        child: outgoing,
      ),
    ],
  );
}

/// Keeps left + right strips of A while the center opening grows.
class _DoorwayDoorsClipper extends CustomClipper<Path> {
  _DoorwayDoorsClipper({required this.progress});

  final double progress;

  @override
  Path getClip(Size size) {
    final doorWidth = size.width * 0.5 * (1.0 - progress.clamp(0.0, 1.0));
    if (doorWidth <= 0.5) return Path();
    return Path()
      ..addRect(Rect.fromLTWH(0, 0, doorWidth, size.height))
      ..addRect(
        Rect.fromLTWH(size.width - doorWidth, 0, doorWidth, size.height),
      );
  }

  @override
  bool shouldReclip(covariant _DoorwayDoorsClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

/// Puzzle left: B in 3 vertical strips — right (L→R), mid (top→down), left (L→R).
/// Puzzle right: mirrored — left (R→L), mid (bottom→up), right (R→L).
Widget puzzleTransitionLayer({
  required Size size,
  required double t,
  required Widget outgoing,
  required Widget incoming,
  required bool reverse,
}) {
  return Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.hardEdge,
    children: [
      outgoing,
      _PuzzleIncomingStrips(
        progress: t.clamp(0.0, 1.0),
        reverse: reverse,
        child: incoming,
      ),
    ],
  );
}

class _PuzzleIncomingStrips extends SingleChildRenderObjectWidget {
  const _PuzzleIncomingStrips({
    required this.progress,
    required this.reverse,
    required super.child,
  });

  final double progress;
  final bool reverse;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderPuzzleIncomingStrips(
      progress: progress,
      reverse: reverse,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPuzzleIncomingStrips renderObject,
  ) {
    renderObject
      ..progress = progress
      ..reverse = reverse;
  }
}

class _RenderPuzzleIncomingStrips extends RenderProxyBox {
  _RenderPuzzleIncomingStrips({
    required double progress,
    required bool reverse,
  })  : _progress = progress,
        _reverse = reverse;

  double _progress;
  double get progress => _progress;
  set progress(double value) {
    if (_progress == value) return;
    _progress = value;
    markNeedsPaint();
  }

  bool _reverse;
  bool get reverse => _reverse;
  set reverse(bool value) {
    if (_reverse == value) return;
    _reverse = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;

    final w = size.width / 3;
    final h = size.height;
    // Phase order selects columns: left-puzzle right→mid→left; right-puzzle left→mid→right.
    final columns = _reverse ? const [0, 1, 2] : const [2, 1, 0];

    for (var phase = 0; phase < 3; phase++) {
      final local = ((_progress - phase / 3) * 3).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final eased = Curves.easeOutCubic.transform(local);
      final col = columns[phase];
      final double dx;
      final double dy;
      if (col == 1) {
        // Middle strip: vertical enter.
        dx = 0;
        dy = (_reverse ? 1 : -1) * h * (1.0 - eased);
      } else {
        // Side strips: horizontal enter.
        dx = (_reverse ? 1 : -1) * w * (1.0 - eased);
        dy = 0;
      }

      final clip = Rect.fromLTWH(col * w, 0, w, h);
      context.pushClipRect(
        needsCompositing,
        offset,
        clip,
        (PaintingContext ctx, Offset origin) {
          ctx.pushTransform(
            needsCompositing,
            origin,
            Matrix4.translationValues(dx, dy, 0),
            (PaintingContext ctx2, Offset o) {
              ctx2.paintChild(child, o);
            },
          );
        },
      );
    }
  }
}

/// Concentric wave. [progress] is the catalog `ripple` value (0 = A, 1 = B).
/// `parameters.intensity` scales only the ring bulge.
class _RippleLayer extends MultiChildRenderObjectWidget {
  _RippleLayer({
    required this.progress,
    required this.layers,
    required this.parameters,
    required Widget outgoing,
    required Widget incoming,
  }) : super(children: [outgoing, incoming]);

  final double progress;
  final List<TransitionLayer> layers;
  final Map<String, double> parameters;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderRipple(
      progress: progress,
      layers: layers,
      parameters: parameters,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRipple renderObject,
  ) {
    renderObject
      ..progress = progress
      ..layers = layers
      ..parameters = parameters;
  }
}

class _RippleParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderRipple extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RippleParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RippleParentData> {
  _RenderRipple({
    required double progress,
    required List<TransitionLayer> layers,
    required Map<String, double> parameters,
  })  : _progress = progress,
        _layers = layers,
        _parameters = parameters;

  double _progress;
  List<TransitionLayer> _layers;
  Map<String, double> _parameters;

  double get progress => _progress;
  set progress(double value) {
    if (_progress == value) return;
    _progress = value;
    markNeedsPaint();
  }

  List<TransitionLayer> get layers => _layers;
  set layers(List<TransitionLayer> value) {
    _layers = value;
    markNeedsPaint();
  }

  Map<String, double> get parameters => _parameters;
  set parameters(Map<String, double> value) {
    _parameters = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RippleParentData) {
      child.parentData = _RippleParentData();
    }
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void performLayout() {
    size = constraints.biggest;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tight(size));
      child = (child.parentData! as _RippleParentData).nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final outgoing = firstChild;
    if (outgoing == null) return;
    final incoming = (outgoing.parentData! as _RippleParentData).nextSibling;
    if (incoming == null) {
      context.paintChild(outgoing, offset);
      return;
    }

    var wave = 0.0;
    final eval = evaluateTransitionLayers(
      layers: layers,
      t: progress,
      parameters: parameters,
    );
    wave = math.max(eval.a.ripple, eval.b.ripple).clamp(0.0, 1.0);
    final intensity = (parameters['intensity'] ?? 0.7).clamp(0.0, 1.0);
    final center = size.center(Offset.zero);
    final maxR = math.sqrt(size.width * size.width + size.height * size.height) * 0.62;
    final front = wave * maxR;
    final ring = math.min(size.width, size.height) * (0.10 + 0.08 * intensity);
    final bulge = math.sin(wave * math.pi) * intensity * 0.22;

    context.paintChild(outgoing, offset);

    final wake = front - ring * 0.35;
    if (wake > 1) {
      _paintDisc(context, offset, incoming, center, wake);
    }

    const bands = 7;
    for (var i = 0; i < bands; i++) {
      final u0 = i / bands;
      final u1 = (i + 1) / bands;
      final r0 = front - ring * 0.2 + u0 * ring * 1.5;
      final r1 = front - ring * 0.2 + u1 * ring * 1.5;
      if (r1 <= 1) continue;
      final phase = (u0 + u1) * 0.5;
      final scale = 1 + math.sin(phase * math.pi) * bulge;
      final child = (r0 + r1) * 0.5 < front ? incoming : outgoing;
      _paintRing(context, offset, child, center, math.max(0, r0), r1, scale);
    }
  }

  void _paintDisc(
    PaintingContext context,
    Offset offset,
    RenderBox child,
    Offset center,
    double radius,
  ) {
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    context.pushClipPath(
      needsCompositing,
      offset,
      Rect.fromCircle(center: center, radius: radius),
      path,
      (
        PaintingContext clipped,
        Offset origin,
      ) {
        clipped.paintChild(child, origin);
      },
    );
  }

  void _paintRing(
    PaintingContext context,
    Offset offset,
    RenderBox child,
    Offset center,
    double inner,
    double outer,
    double scale,
  ) {
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: outer))
      ..addOval(Rect.fromCircle(center: center, radius: inner))
      ..fillType = PathFillType.evenOdd;
    final matrix = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    context.pushClipPath(
      needsCompositing,
      offset,
      Rect.fromCircle(center: center, radius: outer),
      path,
      (
        PaintingContext clipped,
        Offset origin,
      ) {
        clipped.pushTransform(needsCompositing, origin, matrix, (
          PaintingContext transformed,
          Offset childOffset,
        ) {
          transformed.paintChild(child, childOffset);
        });
      },
    );
  }
}

/// Paints catalog layers that use `grid` or `rotationY`.
///
/// Cell layout comes from the first `grid`. Each gridded layer uses its own
/// `stagger`. `rotationY` flips that target; the back face is the other clip.
class _GridLayer extends MultiChildRenderObjectWidget {
  _GridLayer({
    required this.progress,
    required this.layers,
    required this.parameters,
    required Widget outgoing,
    required Widget incoming,
  }) : super(children: [outgoing, incoming]);

  final double progress;
  final List<TransitionLayer> layers;
  final Map<String, double> parameters;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderGridLayer(
      progress: progress,
      layers: layers,
      parameters: parameters,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderGridLayer renderObject,
  ) {
    renderObject
      ..progress = progress
      ..layers = layers
      ..parameters = parameters;
  }
}

class _GridParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderGridLayer extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridParentData> {
  _RenderGridLayer({
    required double progress,
    required List<TransitionLayer> layers,
    required Map<String, double> parameters,
  })  : _progress = progress,
        _layers = layers,
        _parameters = parameters;

  double _progress;
  List<TransitionLayer> _layers;
  Map<String, double> _parameters;

  double get progress => _progress;
  set progress(double value) {
    if (_progress == value) return;
    _progress = value;
    markNeedsPaint();
  }

  List<TransitionLayer> get layers => _layers;
  set layers(List<TransitionLayer> value) {
    _layers = value;
    markNeedsPaint();
  }

  Map<String, double> get parameters => _parameters;
  set parameters(Map<String, double> value) {
    _parameters = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridParentData) {
      child.parentData = _GridParentData();
    }
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void performLayout() {
    size = constraints.biggest;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tight(size));
      child = (child.parentData! as _GridParentData).nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final outgoing = firstChild;
    if (outgoing == null) return;
    final incoming = (outgoing.parentData! as _GridParentData).nextSibling;
    if (incoming == null) {
      context.paintChild(outgoing, offset);
      return;
    }

    final gridLayers = layers.where((layer) => layer.grid != null).toList();
    final cellLayers = gridLayers.isEmpty
        ? layers
            .where((layer) => layer.property == TransitionProperty.rotationY)
            .toList()
        : gridLayers;
    final baseLayers = layers
        .where((layer) => !cellLayers.contains(layer))
        .toList();
    final layout = gridLayers.isEmpty ? null : gridLayers.first.grid;
    final columns = layout?.columns ?? 1;
    final rows = layout?.rows ?? 1;
    final gap = layout?.gap ?? 0;
    final base = baseLayers.isEmpty
        ? const TransitionLayerEvaluation(
            a: TransitionLayerPose(),
            b: TransitionLayerPose(),
          )
        : evaluateTransitionLayers(
            layers: baseLayers,
            t: progress,
            parameters: parameters,
          );

    final canvas = context.canvas;
    canvas.drawRect(offset & size, Paint()..color = const Color(0xFF000000));

    final cellW = size.width / columns;
    final cellH = size.height / rows;
    final hasFlip = cellLayers.any(
      (layer) => layer.property == TransitionProperty.rotationY,
    );
    var flipFront = TransitionLayerTarget.a;
    for (final layer in cellLayers) {
      if (layer.property != TransitionProperty.rotationY) continue;
      if (layer.target != TransitionLayerTarget.both) flipFront = layer.target;
    }

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final index = row * columns + col;
        var eval = base;
        for (final layer in cellLayers) {
          final cellT = gridCellProgress(
            index,
            progress,
            layer.grid?.stagger ?? 0,
          );
          eval = applyTransitionLayers(
            base: eval,
            layers: [layer],
            t: cellT,
            parameters: parameters,
          );
        }
        final gapX = cellW * gap;
        final gapY = cellH * gap;
        final cell = Rect.fromLTWH(
          col * cellW + gapX,
          row * cellH + gapY,
          math.max(0, cellW - gapX * 2),
          math.max(0, cellH - gapY * 2),
        );
        if (cell.width < 0.5 || cell.height < 0.5) continue;
        if (hasFlip) {
          final turns = flipFront == TransitionLayerTarget.b
              ? eval.b.rotationY
              : eval.a.rotationY;
          final face = rotationYFace(turns);
          final showB = flipFront == TransitionLayerTarget.b
              ? !face.showBack
              : face.showBack;
          final pose = showB ? eval.b : eval.a;
          _paintCellFace(
            context,
            offset,
            cell,
            pose,
            showB ? incoming : outgoing,
            faceRadians: face.faceRadians,
          );
        } else {
          final aOnTop = aShouldPaintOnTop(eval, layers: layers);
          final firstPose = aOnTop ? eval.b : eval.a;
          final firstChildBox = aOnTop ? incoming : outgoing;
          final secondPose = aOnTop ? eval.a : eval.b;
          final secondChildBox = aOnTop ? outgoing : incoming;
          _paintCellFace(context, offset, cell, firstPose, firstChildBox);
          _paintCellFace(context, offset, cell, secondPose, secondChildBox);
        }
      }
    }
  }

  void _paintCellFace(
    PaintingContext context,
    Offset offset,
    Rect cell,
    TransitionLayerPose pose,
    RenderBox child, {
    double faceRadians = 0,
  }) {
    if (pose.opacity <= 0.001 || pose.scale.abs() < 0.001 || pose.wipe >= 0.999) {
      return;
    }
    final center = cell.center;
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, faceRadians == 0 ? 0 : 0.0014)
      ..translateByDouble(
        center.dx + pose.translateX * cell.width,
        center.dy + pose.translateY * cell.height,
        0,
        1,
      )
      ..rotateY(faceRadians)
      ..rotateZ(pose.rotation * math.pi * 2)
      ..scaleByDouble(pose.scale, pose.scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    final clip = _wipedCell(cell, pose);
    context.pushTransform(needsCompositing, offset, matrix, (
      PaintingContext transformed,
      Offset transformedOffset,
    ) {
      void paint(PaintingContext clipped, Offset clipOffset) {
        clipped.pushClipRect(needsCompositing, clipOffset, clip, (
          PaintingContext cellCtx,
          Offset origin,
        ) {
          cellCtx.paintChild(child, origin);
        });
      }

      if (pose.opacity >= 0.999) {
        paint(transformed, transformedOffset);
        return;
      }
      transformed.pushOpacity(
        transformedOffset,
        (pose.opacity.clamp(0.0, 1.0) * 255).round(),
        paint,
      );
    });
  }

  Rect _wipedCell(Rect cell, TransitionLayerPose pose) {
    final w = pose.wipe.clamp(0.0, 1.0);
    if (w <= 0.001) return cell;
    switch (pose.wipeEdge) {
      case 'right':
        return Rect.fromLTWH(cell.left, cell.top, cell.width * (1 - w), cell.height);
      case 'top':
        return Rect.fromLTWH(
          cell.left,
          cell.top + cell.height * w,
          cell.width,
          cell.height * (1 - w),
        );
      case 'bottom':
        return Rect.fromLTWH(cell.left, cell.top, cell.width, cell.height * (1 - w));
      case 'left':
      default:
        return Rect.fromLTWH(
          cell.left + cell.width * w,
          cell.top,
          cell.width * (1 - w),
          cell.height,
        );
    }
  }
}

/// Convenience: build from an [AppliedTransition] + catalog definition.
class TransitionLayerCompositorFromPlan extends StatelessWidget {
  const TransitionLayerCompositorFromPlan({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.t,
    required this.definition,
    required this.applied,
  });

  final Widget outgoing;
  final Widget incoming;
  final double t;
  final TransitionItem definition;
  final AppliedTransition applied;

  @override
  Widget build(BuildContext context) {
    return TransitionLayerCompositor(
      outgoing: outgoing,
      incoming: incoming,
      t: t,
      layers: definition.layers,
      parameters: {
        ...definition.defaultParameters(),
        ...applied.parameters,
      },
    );
  }
}
