import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/widgets/transition_layer_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transition layer runtime', () {
    test('evaluates start/end windows and intensity param', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 1.8,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
          start: 0,
          end: 0.5,
          param: 'intensity',
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1.8,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
          start: 0.5,
          end: 1,
          param: 'intensity',
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
          start: 0.4,
          end: 0.6,
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 0,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
          start: 0.4,
          end: 0.6,
        ),
      ];

      final midZoom = evaluateTransitionLayers(
        layers: layers,
        t: 0.25,
        parameters: const {'intensity': 1},
      );
      expect(midZoom.a.scale, closeTo(1.4, 0.001));
      expect(midZoom.a.opacity, 1);
      expect(midZoom.b.opacity, 0);

      final handoff = evaluateTransitionLayers(
        layers: layers,
        t: 0.5,
        parameters: const {'intensity': 1},
      );
      expect(handoff.a.scale, closeTo(1.8, 0.001));
      expect(handoff.b.scale, closeTo(1.8, 0.001));
      expect(handoff.a.opacity, closeTo(0.5, 0.001));
      expect(handoff.b.opacity, closeTo(0.5, 0.001));

      final soft = evaluateTransitionLayers(
        layers: layers,
        t: 0.25,
        parameters: const {'intensity': 0.5},
      );
      // Peak 1.8 at intensity 1 → 1.4 at intensity 0.5; midpoint of zoom-in.
      expect(soft.a.scale, closeTo(1.2, 0.001));
    });

    test('fills complementary opacity when only one side is authored', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
        ),
      ];
      final eval = evaluateTransitionLayers(layers: layers, t: 0.25);
      expect(eval.a.opacity, closeTo(0.75, 0.001));
      expect(eval.b.opacity, closeTo(0.25, 0.001));
    });

    test('translate-only slide keeps both clips fully opaque', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.translateX,
          from: 0,
          to: -1,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.easeInOut,
        ),
        TransitionLayer(
          property: TransitionProperty.translateX,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.easeInOut,
        ),
      ];
      final mid = evaluateTransitionLayers(layers: layers, t: 0.5);
      expect(mid.a.opacity, 1);
      expect(mid.b.opacity, 1);
      expect(mid.a.translateX, closeTo(-0.5, 0.05));
      expect(mid.b.translateX, closeTo(0.5, 0.05));
    });

    test('parses start/end/param from json', () {
      final layer = TransitionLayer.fromJson({
        'property': 'scale',
        'from': 1,
        'to': 2,
        'start': 0.2,
        'end': 0.8,
        'param': 'intensity',
        'target': 'B',
        'easing': 'easeInOut',
      });
      expect(layer.start, 0.2);
      expect(layer.end, 0.8);
      expect(layer.param, 'intensity');
      expect(layer.target, TransitionLayerTarget.b);
    });

    test('fade-to-black brightness ramps instead of jumping', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 0,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.brightness,
          from: 0,
          to: -1,
          target: TransitionLayerTarget.both,
          easing: TransitionEasing.linear,
          start: 0,
          end: 0.5,
        ),
        TransitionLayer(
          property: TransitionProperty.brightness,
          from: -1,
          to: 0,
          target: TransitionLayerTarget.both,
          easing: TransitionEasing.linear,
          start: 0.5,
          end: 1,
        ),
      ];

      final early = evaluateTransitionLayers(layers: layers, t: 0.25);
      expect(early.a.brightness, closeTo(-0.5, 0.001));
      expect(early.b.brightness, closeTo(-0.5, 0.001));
      expect(early.a.opacity, closeTo(0.75, 0.001));

      final mid = evaluateTransitionLayers(layers: layers, t: 0.5);
      expect(mid.a.brightness, closeTo(-1.0, 0.001));
      expect(mid.b.brightness, closeTo(-1.0, 0.001));

      final late = evaluateTransitionLayers(layers: layers, t: 0.75);
      expect(late.a.brightness, closeTo(-0.5, 0.001));
      expect(late.b.brightness, closeTo(-0.5, 0.001));
      expect(late.b.opacity, closeTo(0.75, 0.001));
    });

    test('spin in/out keep both clips opaque with correct mover', () {
      const spinIn = [
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: -0.12,
          to: 0,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 0.4,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
      ];
      final inMid = evaluateTransitionLayers(layers: spinIn, t: 0.5);
      expect(inMid.a.opacity, 1);
      expect(inMid.b.opacity, 1);
      expect(inMid.b.scale, closeTo(0.7, 0.001));
      expect(inMid.a.scale, 1);
      expect(inMid.b.rotation, closeTo(-0.06, 0.001));
      expect(inMid.a.rotation, 0);

      const spinOut = [
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: 0,
          to: 0.12,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
      ];
      final outMid = evaluateTransitionLayers(layers: spinOut, t: 0.5);
      expect(outMid.a.opacity, 1);
      expect(outMid.b.opacity, 1);
      expect(outMid.a.scale, closeTo(0.5, 0.001));
      expect(outMid.b.scale, 1);
      expect(outMid.a.rotation, closeTo(0.06, 0.001));
      expect(outMid.b.rotation, 0);
    });

    test('role effect resolves from effect.kind, never catalog id', () {
      final doorway = TransitionItem(
        id: 'renamed-door',
        title: 'Door',
        effectName: 'horzopen',
        defaultDurationMs: 700,
        accent: '#fff',
        renderer: TransitionRendererKind.custom,
        effect: const {
          'kind': 'doorway',
          'incomingScaleFrom': 0.5,
          'incomingScaleTo': 1.0,
        },
      );
      final role = TransitionRoleEffect.resolve(doorway)!;
      expect(role.isDoorway, isTrue);
      expect(role.incomingScaleFrom, 0.5);
      expect(doorway.hasRoleCompositor, isTrue);

      // Catalog id alone must not trigger a role compositor.
      final byIdOnly = TransitionItem(
        id: 'doorway',
        title: 'Doorway',
        effectName: 'horzopen',
        defaultDurationMs: 700,
        accent: '#fff',
        renderer: TransitionRendererKind.primitive,
      );
      expect(TransitionRoleEffect.resolve(byIdOnly), isNull);
    });

    test('puzzle effect resolves from effect.kind + reverse param', () {
      final left = TransitionItem(
        id: 'whatever-left',
        title: 'Puzzle',
        effectName: 'wipeleft',
        defaultDurationMs: 700,
        accent: '#fff',
        renderer: TransitionRendererKind.custom,
        effect: const {'kind': 'puzzle', 'reverse': false},
      );
      final right = TransitionItem(
        id: 'whatever-right',
        title: 'Puzzle',
        effectName: 'wiperight',
        defaultDurationMs: 700,
        accent: '#fff',
        renderer: TransitionRendererKind.custom,
        effect: const {'kind': 'puzzle', 'reverse': true},
      );
      expect(TransitionRoleEffect.resolve(left)!.reverse, isFalse);
      expect(TransitionRoleEffect.resolve(right)!.reverse, isTrue);

      // Legacy customId still works when effect is absent.
      final legacy = TransitionItem(
        id: 'old-puzzle',
        title: 'Puzzle',
        effectName: 'wipeleft',
        defaultDurationMs: 700,
        accent: '#fff',
        customId: 'puzzleright',
      );
      expect(TransitionRoleEffect.resolve(legacy)!.isPuzzle, isTrue);
      expect(TransitionRoleEffect.resolve(legacy)!.reverse, isTrue);
    });

    test('wipe layer property clips A over static B', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.wipe,
          from: 0,
          to: 1,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
          mode: 'left',
        ),
      ];
      final mid = evaluateTransitionLayers(layers: layers, t: 0.5);
      expect(mid.a.opacity, 1);
      expect(mid.b.opacity, 1);
      expect(mid.a.wipe, closeTo(0.5, 0.001));
      expect(mid.a.wipeEdge, 'left');
      expect(mid.b.wipe, 0);
      expect(aShouldPaintOnTop(mid, layers: layers), isTrue);
    });

    test('aShouldPaintOnTop follows last A/B target in layers', () {
      // Backdrop B (identity) then A mover last → A on top.
      const spinOutLayers = [
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: 0,
          to: 0.12,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.easeIn,
        ),
      ];
      final spinOutStart = evaluateTransitionLayers(layers: spinOutLayers, t: 0);
      expect(
        aShouldPaintOnTop(spinOutStart, layers: spinOutLayers),
        isTrue,
      );
      final spinOut = evaluateTransitionLayers(layers: spinOutLayers, t: 0.5);
      expect(aShouldPaintOnTop(spinOut, layers: spinOutLayers), isTrue);

      // Backdrop A then B mover last → B on top.
      const spinInLayers = [
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 1,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: -0.12,
          to: 0,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 0.4,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
      ];
      final spinIn = evaluateTransitionLayers(layers: spinInLayers, t: 0.5);
      expect(aShouldPaintOnTop(spinIn, layers: spinInLayers), isFalse);

      // Same A motion but B authored last → B on top (flexible override).
      const aMovesButBOnTop = [
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.a,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 1,
          target: TransitionLayerTarget.b,
          easing: TransitionEasing.linear,
        ),
      ];
      expect(
        aShouldPaintOnTop(
          evaluateTransitionLayers(layers: aMovesButBOnTop, t: 0.5),
          layers: aMovesButBOnTop,
        ),
        isFalse,
      );
    });
  });
}
