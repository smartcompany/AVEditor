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
  });
}
