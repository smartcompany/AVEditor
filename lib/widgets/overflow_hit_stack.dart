import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [Stack] that hit-tests positioned children even outside its layout bounds.
///
/// Needed when overlay resize handles extend into letterbox / past the preview
/// edge — default [RenderBox.hitTest] rejects touches beyond `size`.
class OverflowHitStack extends Stack {
  const OverflowHitStack({
    super.key,
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
    super.children,
  });

  @override
  RenderStack createRenderObject(BuildContext context) {
    return RenderOverflowHitStack(
      alignment: alignment,
      textDirection: textDirection ?? Directionality.of(context),
      fit: fit,
      clipBehavior: clipBehavior,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderOverflowHitStack renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..textDirection = textDirection ?? Directionality.of(context)
      ..fit = fit
      ..clipBehavior = clipBehavior;
  }
}

class RenderOverflowHitStack extends RenderStack {
  RenderOverflowHitStack({
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
    super.children,
  });

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return hitTestSelf(position);
  }
}

/// Proxy that hit-tests its child even when [position] is outside [size].
class OverflowHitBox extends SingleChildRenderObjectWidget {
  const OverflowHitBox({super.key, super.child});

  @override
  RenderOverflowHitBox createRenderObject(BuildContext context) =>
      RenderOverflowHitBox();
}

class RenderOverflowHitBox extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return hitTestSelf(position);
  }
}

/// Fixed layout size, but forwards hit tests outside [size] to the child.
///
/// [SizedBox] rejects touches beyond its bounds — this breaks overlay handles
/// that extend into letterbox / past the preview edge.
class OverflowSizedBox extends SingleChildRenderObjectWidget {
  const OverflowSizedBox({
    super.key,
    required this.width,
    required this.height,
    super.child,
  });

  final double width;
  final double height;

  @override
  RenderOverflowSizedBox createRenderObject(BuildContext context) {
    return RenderOverflowSizedBox(width, height);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderOverflowSizedBox renderObject,
  ) {
    renderObject
      ..width = width
      ..height = height;
  }
}

class RenderOverflowSizedBox extends RenderProxyBox {
  RenderOverflowSizedBox(this._width, this._height);

  double _width;
  double _height;

  set width(double value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  set height(double value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(_width, _height));
    if (child != null) {
      child!.layout(BoxConstraints.tight(size));
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
