import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorSheetMetrics', () {
    testWidgets('compact < entry < max fractions', (tester) async {
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
      expect(metrics.compactFraction, EditorSheetMetrics.compactFractionValue);
      expect(metrics.entryFraction, EditorSheetMetrics.entryFractionValue);
      expect(metrics.maxFraction, EditorSheetMetrics.maxFractionValue);
      expect(metrics.compactHeight, closeTo(844 * 0.30, 0.001));
      expect(metrics.entryHeight, closeTo(844 * 0.45, 0.001));
      expect(metrics.maxHeight, closeTo(844 * 2 / 3, 0.001));
      expect(metrics.compactHeight, lessThan(metrics.entryHeight));
      expect(metrics.entryHeight, lessThan(metrics.maxHeight));
    });
  });

  group('dockHeightStops', () {
    test('four stages: hidden, compact, entry, max', () {
      final stops = dockHeightStops(
        entryHeight: 320,
        maxHeight: 600,
        compactHeight: 160,
      );
      expect(stops, [0.0, 160.0, 320.0, 600.0]);
    });

    test('defaults compact to half entry when omitted', () {
      final stops = dockHeightStops(entryHeight: 320, maxHeight: 600);
      expect(stops, [0.0, 160.0, 320.0, 600.0]);
    });

    test('collapses near-duplicate stops', () {
      final stops = dockHeightStops(
        entryHeight: 580,
        maxHeight: 600,
        compactHeight: 20,
      );
      expect(stops.first, 0.0);
      expect(stops.last, 600.0);
      expect(stops.length, lessThanOrEqualTo(3));
    });
  });

  group('snapDockHeight', () {
    const stops = [0.0, 160.0, 320.0, 600.0];

    test('fling down from max lands on entry, not compact', () {
      expect(
        snapDockHeight(current: 600, velocity: 500, stops: stops),
        320.0,
      );
    });

    test('fling down from entry lands on compact', () {
      expect(
        snapDockHeight(current: 320, velocity: 500, stops: stops),
        160.0,
      );
    });

    test('fling down from compact lands on hidden (full video)', () {
      expect(
        snapDockHeight(current: 160, velocity: 500, stops: stops),
        0.0,
      );
    });

    test('fling up from hidden lands on compact', () {
      expect(
        snapDockHeight(current: 0.0, velocity: -500, stops: stops),
        160.0,
      );
    });

    test('fling up from compact lands on entry', () {
      expect(
        snapDockHeight(current: 160, velocity: -500, stops: stops),
        320.0,
      );
    });

    test('slow release snaps to nearest stop', () {
      expect(
        snapDockHeight(current: 520, velocity: 0, stops: stops),
        600.0,
      );
      expect(
        snapDockHeight(current: 280, velocity: 0, stops: stops),
        320.0,
      );
      expect(
        snapDockHeight(current: 100, velocity: 0, stops: stops),
        160.0,
      );
      expect(
        snapDockHeight(current: 40, velocity: 0, stops: stops),
        0.0,
      );
    });
  });
}
