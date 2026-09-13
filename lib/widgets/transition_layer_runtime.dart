import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:flutter/material.dart';

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
    this.blur = 0,
    this.brightness = 0,
  });

  final double opacity;
  final double scale;
  /// Frame-normalized (-1 = full width left, 1 = full width right).
  final double translateX;
  final double translateY;
  /// Turns (1.0 = 360°).
  final double rotation;
  final double blur;
  /// -1…1 style lift used as a white/black overlay.
  final double brightness;

  TransitionLayerPose copyWith({
    double? opacity,
    double? scale,
    double? translateX,
    double? translateY,
    double? rotation,
    double? blur,
    double? brightness,
  }) {
    return TransitionLayerPose(
      opacity: opacity ?? this.opacity,
      scale: scale ?? this.scale,
      translateX: translateX ?? this.translateX,
      translateY: translateY ?? this.translateY,
      rotation: rotation ?? this.rotation,
      blur: blur ?? this.blur,
      brightness: brightness ?? this.brightness,
    );
  }
}

class TransitionLayerEvaluation {
  const TransitionLayerEvaluation({
    required this.outgoing,
    required this.incoming,
  });

  final TransitionLayerPose outgoing;
  final TransitionLayerPose incoming;
}

/// Pure evaluation of catalog layers — no Flutter widgets.
TransitionLayerEvaluation evaluateTransitionLayers({
  required List<TransitionLayer> layers,
  required double t,
  Map<String, double> parameters = const {},
}) {
  final progress = t.clamp(0.0, 1.0);
  var outgoing = const TransitionLayerPose(opacity: 1);
  var incoming = const TransitionLayerPose(opacity: 0);

  final hasOpacity = layers.any((l) => l.property == TransitionProperty.opacity);
  var outgoingOpacitySet = false;
  var incomingOpacitySet = false;

  for (final layer in layers) {
    final value = evaluateTransitionLayer(
      layer,
      progress,
      parameters: parameters,
    );
    if (layer.target == TransitionLayerTarget.outgoing ||
        layer.target == TransitionLayerTarget.both) {
      outgoing = _applyProperty(outgoing, layer.property, value);
      if (layer.property == TransitionProperty.opacity) {
        outgoingOpacitySet = true;
      }
    }
    if (layer.target == TransitionLayerTarget.incoming ||
        layer.target == TransitionLayerTarget.both) {
      incoming = _applyProperty(incoming, layer.property, value);
      if (layer.property == TransitionProperty.opacity) {
        incomingOpacitySet = true;
      }
    }
  }

  if (!hasOpacity) {
    // Spatial motion (slide/push) should stay solid — auto crossfade makes
    // the two clips ghost through each other and looks unnatural.
    final spatial = layers.any(
      (l) =>
          l.property == TransitionProperty.translateX ||
          l.property == TransitionProperty.translateY ||
          l.property == TransitionProperty.rotation,
    );
    if (spatial) {
      outgoing = outgoing.copyWith(opacity: 1);
      incoming = incoming.copyWith(opacity: 1);
    } else {
      outgoing = outgoing.copyWith(opacity: 1 - progress);
      incoming = incoming.copyWith(opacity: progress);
    }
  } else if (outgoingOpacitySet && !incomingOpacitySet) {
    incoming = incoming.copyWith(opacity: (1 - outgoing.opacity).clamp(0.0, 1.0));
  } else if (incomingOpacitySet && !outgoingOpacitySet) {
    outgoing = outgoing.copyWith(opacity: (1 - incoming.opacity).clamp(0.0, 1.0));
  }

  return TransitionLayerEvaluation(outgoing: outgoing, incoming: incoming);
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
    case TransitionProperty.blur:
    case TransitionProperty.brightness:
    case TransitionProperty.saturation:
    case TransitionProperty.contrast:
      return 0;
  }
}

TransitionLayerPose _applyProperty(
  TransitionLayerPose pose,
  TransitionProperty property,
  double value,
) {
  switch (property) {
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
    case TransitionProperty.blur:
      return pose.copyWith(blur: value);
    case TransitionProperty.brightness:
      return pose.copyWith(brightness: value);
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
        if (isConveyorSlidePose(eval.outgoing, eval.incoming)) {
          return conveyorSlideLayer(
            size: size,
            outgoing: eval.outgoing,
            incoming: eval.incoming,
            outgoingChild: outgoing,
            incomingChild: incoming,
          );
        }
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            posedTransitionLayer(eval.outgoing, size, outgoing),
            posedTransitionLayer(eval.incoming, size, incoming),
          ],
        );
      },
    );
  }
}

/// Applies a catalog pose to a child (shared by picker + live dual-slot preview).
Widget posedTransitionLayer(TransitionLayerPose pose, Size size, Widget child) {
  Widget built = child;
  if (pose.blur.abs() > 0.3) {
    built = ImageFiltered(
      imageFilter: ImageFilter.blur(
        sigmaX: pose.blur.abs(),
        sigmaY: pose.blur.abs(),
      ),
      child: built,
    );
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
