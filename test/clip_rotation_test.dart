import 'dart:math' as math;

import 'package:aveditor/utils/clip_rotation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeClipRotation', () {
    test('folds into (-pi, pi]', () {
      expect(normalizeClipRotation(0), 0);
      expect(normalizeClipRotation(math.pi), closeTo(math.pi, 1e-9));
      expect(normalizeClipRotation(-math.pi), closeTo(math.pi, 1e-9));
      expect(normalizeClipRotation(3 * math.pi), closeTo(math.pi, 1e-9));
      expect(normalizeClipRotation(-3 * math.pi), closeTo(math.pi, 1e-9));
    });

    test('kills floating-point dust near zero', () {
      expect(normalizeClipRotation(1e-12), 0);
    });
  });

  group('snapClipRotation', () {
    test('snaps within three degrees of a quarter turn', () {
      expect(snapClipRotation(quarterTurn + 0.02), quarterTurn);
      expect(snapClipRotation(-quarterTurn - 0.02), -quarterTurn);
      expect(snapClipRotation(math.pi / 4), closeTo(math.pi / 4, 1e-9));
    });
  });

  group('twistDelta', () {
    test('crosses the +/-pi boundary without jumping a full turn', () {
      final delta = twistDelta(math.pi - 0.1, -math.pi + 0.1);
      expect(delta, closeTo(0.2, 1e-9));
    });
  });
}
