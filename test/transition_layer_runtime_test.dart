import 'package:aveditor/models/transition_item.dart';
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
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.linear,
          start: 0,
          end: 0.5,
          param: 'intensity',
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1.8,
          to: 1,
          target: TransitionLayerTarget.incoming,
          easing: TransitionEasing.linear,
          start: 0.5,
          end: 1,
          param: 'intensity',
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.linear,
          start: 0.4,
          end: 0.6,
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 0,
          to: 1,
          target: TransitionLayerTarget.incoming,
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
      expect(midZoom.outgoing.scale, closeTo(1.4, 0.001));
      expect(midZoom.outgoing.opacity, 1);
      expect(midZoom.incoming.opacity, 0);

      final handoff = evaluateTransitionLayers(
        layers: layers,
        t: 0.5,
        parameters: const {'intensity': 1},
      );
      expect(handoff.outgoing.scale, closeTo(1.8, 0.001));
      expect(handoff.incoming.scale, closeTo(1.8, 0.001));
      expect(handoff.outgoing.opacity, closeTo(0.5, 0.001));
      expect(handoff.incoming.opacity, closeTo(0.5, 0.001));

      final soft = evaluateTransitionLayers(
        layers: layers,
        t: 0.25,
        parameters: const {'intensity': 0.5},
      );
      // Peak 1.8 at intensity 1 → 1.4 at intensity 0.5; midpoint of zoom-in.
      expect(soft.outgoing.scale, closeTo(1.2, 0.001));
    });

    test('fills complementary opacity when only one side is authored', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.outgoing,
        ),
      ];
      final eval = evaluateTransitionLayers(layers: layers, t: 0.25);
      expect(eval.outgoing.opacity, closeTo(0.75, 0.001));
      expect(eval.incoming.opacity, closeTo(0.25, 0.001));
    });

    test('translate-only slide keeps both clips fully opaque', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.translateX,
          from: 0,
          to: -1,
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.easeInOut,
        ),
        TransitionLayer(
          property: TransitionProperty.translateX,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.incoming,
          easing: TransitionEasing.easeInOut,
        ),
      ];
      final mid = evaluateTransitionLayers(layers: layers, t: 0.5);
      expect(mid.outgoing.opacity, 1);
      expect(mid.incoming.opacity, 1);
      expect(mid.outgoing.translateX, closeTo(-0.5, 0.05));
      expect(mid.incoming.translateX, closeTo(0.5, 0.05));
    });

    test('parses start/end/param from json', () {
      final layer = TransitionLayer.fromJson({
        'property': 'scale',
        'from': 1,
        'to': 2,
        'start': 0.2,
        'end': 0.8,
        'param': 'intensity',
        'target': 'incoming',
        'easing': 'easeInOut',
      });
      expect(layer.start, 0.2);
      expect(layer.end, 0.8);
      expect(layer.param, 'intensity');
      expect(layer.target, TransitionLayerTarget.incoming);
    });

    test('fade-to-black brightness ramps instead of jumping', () {
      const layers = [
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 1,
          to: 0,
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.opacity,
          from: 0,
          to: 1,
          target: TransitionLayerTarget.incoming,
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
      expect(early.outgoing.brightness, closeTo(-0.5, 0.001));
      expect(early.incoming.brightness, closeTo(-0.5, 0.001));
      expect(early.outgoing.opacity, closeTo(0.75, 0.001));

      final mid = evaluateTransitionLayers(layers: layers, t: 0.5);
      expect(mid.outgoing.brightness, closeTo(-1.0, 0.001));
      expect(mid.incoming.brightness, closeTo(-1.0, 0.001));

      final late = evaluateTransitionLayers(layers: layers, t: 0.75);
      expect(late.outgoing.brightness, closeTo(-0.5, 0.001));
      expect(late.incoming.brightness, closeTo(-0.5, 0.001));
      expect(late.incoming.opacity, closeTo(0.75, 0.001));
    });

    test('spin in/out keep both clips opaque with correct mover', () {
      const spinIn = [
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: -0.12,
          to: 0,
          target: TransitionLayerTarget.incoming,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 0.4,
          to: 1,
          target: TransitionLayerTarget.incoming,
          easing: TransitionEasing.linear,
        ),
      ];
      final inMid = evaluateTransitionLayers(layers: spinIn, t: 0.5);
      expect(inMid.outgoing.opacity, 1);
      expect(inMid.incoming.opacity, 1);
      expect(inMid.incoming.scale, closeTo(0.7, 0.001));
      expect(inMid.outgoing.scale, 1);
      expect(inMid.incoming.rotation, closeTo(-0.06, 0.001));
      expect(inMid.outgoing.rotation, 0);

      const spinOut = [
        TransitionLayer(
          property: TransitionProperty.rotation,
          from: 0,
          to: 0.12,
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.linear,
        ),
        TransitionLayer(
          property: TransitionProperty.scale,
          from: 1,
          to: 0.4,
          target: TransitionLayerTarget.outgoing,
          easing: TransitionEasing.linear,
        ),
      ];
      final outMid = evaluateTransitionLayers(layers: spinOut, t: 0.5);
      expect(outMid.outgoing.opacity, 1);
      expect(outMid.incoming.opacity, 1);
      expect(outMid.outgoing.scale, closeTo(0.7, 0.001));
      expect(outMid.incoming.scale, 1);
      expect(outMid.outgoing.rotation, closeTo(0.06, 0.001));
      expect(outMid.incoming.rotation, 0);
    });

    test('doorway effect is detected by id and customId', () {
      expect(isDoorwayEffect(id: 'doorway'), isTrue);
      expect(isDoorwayEffect(customId: 'doorway'), isTrue);
      expect(isDoorwayEffect(id: 'dissolve'), isFalse);
      expect(isRoleSpecialEffect(id: 'doorway'), isTrue);
      expect(isRoleSpecialEffect(id: 'swap'), isFalse);
    });

    test('puzzle effect is detected by id and customId', () {
      expect(isPuzzleLeftEffect(id: 'puzzleleft'), isTrue);
      expect(isPuzzleRightEffect(customId: 'puzzleright'), isTrue);
      expect(isPuzzleEffect(id: 'puzzleleft'), isTrue);
      expect(isRoleSpecialEffect(id: 'puzzleright'), isTrue);
      expect(isPuzzleEffect(id: 'doorway'), isFalse);
    });

    test('outgoingShouldPaintOnTop is true for spin-out poses', () {
      final spinOut = evaluateTransitionLayers(
        layers: const [
          TransitionLayer(
            property: TransitionProperty.rotation,
            from: 0,
            to: 0.12,
            target: TransitionLayerTarget.outgoing,
            easing: TransitionEasing.linear,
          ),
          TransitionLayer(
            property: TransitionProperty.scale,
            from: 1,
            to: 0.4,
            target: TransitionLayerTarget.outgoing,
            easing: TransitionEasing.linear,
          ),
        ],
        t: 0.5,
      );
      expect(outgoingShouldPaintOnTop(spinOut), isTrue);

      final spinIn = evaluateTransitionLayers(
        layers: const [
          TransitionLayer(
            property: TransitionProperty.rotation,
            from: -0.12,
            to: 0,
            target: TransitionLayerTarget.incoming,
            easing: TransitionEasing.linear,
          ),
          TransitionLayer(
            property: TransitionProperty.scale,
            from: 0.4,
            to: 1,
            target: TransitionLayerTarget.incoming,
            easing: TransitionEasing.linear,
          ),
        ],
        t: 0.5,
      );
      expect(outgoingShouldPaintOnTop(spinIn), isFalse);
    });
  });
}
