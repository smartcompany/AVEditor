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
      textDirection: textDirection,
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
      ..textDirection = textDirection
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
