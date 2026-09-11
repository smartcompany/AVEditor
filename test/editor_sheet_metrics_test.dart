import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorSheetMetrics', () {
    testWidgets('entry is 1/3 screen, max is 2/3', (tester) async {
      late EditorSheetMetrics metrics;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Builder(
            builder: (context) {
              metrics = EditorSheetMetrics.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(metrics.entryFraction, EditorSheetMetrics.entryFractionValue);
      expect(metrics.maxFraction, EditorSheetMetrics.maxFractionValue);
      expect(metrics.entryHeight, closeTo(844 / 3, 0.001));
      expect(metrics.maxHeight, closeTo(844 * 2 / 3, 0.001));
    });
  });

  group('dockHeightStops', () {
    test('three stages: hidden, entry 1/3, max 2/3', () {
      final stops = dockHeightStops(entryHeight: 320, maxHeight: 600);
      expect(stops, [0.0, 320.0, 600.0]);
    });

    test('collapses to two stops when entry ≈ max', () {
      final stops = dockHeightStops(entryHeight: 580, maxHeight: 600);
      expect(stops.length, 2);
      expect(stops.first, 0.0);
      expect(stops.last, 600.0);
    });
  });

  group('snapDockHeight', () {
    const stops = [0.0, 320.0, 600.0];

    test('fling down from 2/3 lands on panel entry, not hidden', () {
      expect(
        snapDockHeight(current: 600, velocity: 500, stops: stops),
        320.0,
      );
    });

    test('fling down from entry lands on hidden (full video)', () {
      expect(
        snapDockHeight(current: 320, velocity: 500, stops: stops),
        0.0,
      );
    });

    test('fling up from entry lands on 2/3 panel', () {
      expect(
        snapDockHeight(current: 320, velocity: -500, stops: stops),
        600.0,
      );
    });

    test('fling up from hidden lands on panel entry', () {
      expect(
        snapDockHeight(current: 0.0, velocity: -500, stops: stops),
        320.0,
      );
    });

    test('slow release snaps to nearest stop', () {
      expect(
        snapDockHeight(current: 520, velocity: 0, stops: stops),
        600.0,
      );
      expect(
        snapDockHeight(current: 200, velocity: 0, stops: stops),
        320.0,
      );
      expect(
        snapDockHeight(current: 80, velocity: 0, stops: stops),
        0.0,
      );
    });
  });
}
