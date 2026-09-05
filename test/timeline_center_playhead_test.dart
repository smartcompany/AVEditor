import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewport = 400.0;
  const total = Duration(seconds: 100);

  double centreXFor(Duration playhead, {double zoom = 1}) {
    final contentWidth = viewport * zoom;
    return durationToViewportX(
      time: playhead,
      scrollPx: scrollPxForPlayhead(
        playhead: playhead,
        total: total,
        contentWidth: contentWidth,
      ),
      total: total,
      contentWidth: contentWidth,
      contentInsetX: timelineContentInsetX(viewport),
    );
  }

  group('playhead geometry', () {
    test('the playhead sits at the viewport centre at every time and zoom', () {
      for (final zoom in [
        minTimelineZoom,
        1.0,
        4.0,
        maxTimelineZoomFor(total, viewportWidth: viewport),
      ]) {
        for (final seconds in [0, 1, 50, 99, 100]) {
          expect(
            centreXFor(Duration(seconds: seconds), zoom: zoom),
            closeTo(viewport / 2, 0.001),
            reason: 'zoom $zoom at ${seconds}s',
          );
        }
      }
    });

    test('a freshly loaded clip starts under the indicator', () {
      final startX = durationToViewportX(
        time: Duration.zero,
        scrollPx: scrollPxForPlayhead(
          playhead: Duration.zero,
          total: total,
          contentWidth: viewport,
        ),
        total: total,
        contentWidth: viewport,
        contentInsetX: timelineContentInsetX(viewport),
      );

      expect(startX, closeTo(viewport / 2, 0.001));
    });

    test('the clip end reaches the indicator, so no tail is unreachable', () {
      expect(centreXFor(total), closeTo(viewport / 2, 0.001));
    });

    test('viewport x and time round-trip through the centre inset', () {
      const playhead = Duration(seconds: 30);
      final scrollPx = scrollPxForPlayhead(
        playhead: playhead,
        total: total,
        contentWidth: viewport,
      );

      for (final x in [0.0, 120.0, viewport / 2, viewport]) {
        final time = viewportXToDuration(
          x: x,
          scrollPx: scrollPx,
          total: total,
          contentWidth: viewport,
          contentInsetX: timelineContentInsetX(viewport),
        );
        final back = durationToViewportX(
          time: time,
          scrollPx: scrollPx,
          total: total,
          contentWidth: viewport,
          contentInsetX: timelineContentInsetX(viewport),
        );
        // Times outside the clip clamp, so only in-range x round-trips.
        if (time > Duration.zero && time < total) {
          expect(back, closeTo(x, 0.5), reason: 'x=$x');
        }
      }
    });

    test('at zoom 1 half the clip is off each side of the indicator', () {
      final scrollPx = scrollPxForPlayhead(
        playhead: const Duration(seconds: 50),
        total: total,
        contentWidth: viewport,
      );

      expect(scrollPx, closeTo(viewport / 2, 0.001));
    });

    test('shortening the sequence does not widen earlier clips', () {
      const source = Duration(seconds: 100);
      const first = Duration(seconds: 40);
      final fullWidth = timelineContentWidth(
        sequenceDuration: source,
        scaleReference: source,
        viewportWidth: viewport,
        zoom: 1,
      );
      final firstPxFull = durationToContentX(first, source, fullWidth);

      const shortened = Duration(seconds: 70); // e.g. trimmed the tail
      final shortWidth = timelineContentWidth(
        sequenceDuration: shortened,
        scaleReference: source,
        viewportWidth: viewport,
        zoom: 1,
      );
      final firstPxShort = durationToContentX(first, shortened, shortWidth);

      expect(firstPxShort, closeTo(firstPxFull, 0.001));
      expect(shortWidth, lessThan(fullWidth));
    });

    test('at max zoom a 1s clip is 40 logical px on any viewport', () {
      const source = Duration(seconds: 184);
      for (final vp in [320.0, 390.0, 430.0]) {
        final zoom = maxTimelineZoomFor(source, viewportWidth: vp);
        final width = timelineContentWidth(
          sequenceDuration: source,
          scaleReference: source,
          viewportWidth: vp,
          zoom: zoom,
        );
        final oneSecondPx = durationToContentX(
          const Duration(seconds: 1),
          source,
          width,
        );
        expect(oneSecondPx, closeTo(maxZoomOneSecondLogicalWidth, 0.05));
      }
    });
  });

  group('panning', () {
    testWidgets('dragging the strip moves time, not the indicator', (
      tester,
    ) async {
      final reported = <Duration>[];
      var playhead = const Duration(seconds: 50);

      await tester.pumpWidget(
        _TimelineHarness(
          total: total,
          initialPlayhead: playhead,
          viewportWidth: viewport,
          onPlayheadChanged: (value) {
            playhead = value;
            reported.add(value);
          },
        ),
      );

      final painter = tester.getRect(find.byType(CustomPaint).last);
      final origin = Offset(painter.left + viewport / 2, painter.center.dy);

      // 40 of 400 content px at zoom 1 is a tenth of a 100s clip.
      final gesture = await tester.startGesture(origin);
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(reported, isNotEmpty);
      expect(playhead.inMilliseconds, closeTo(60000, 100));
    });

    testWidgets('dragging right rewinds and stops at zero', (tester) async {
      var playhead = const Duration(seconds: 5);

      await tester.pumpWidget(
        _TimelineHarness(
          total: total,
          initialPlayhead: playhead,
          viewportWidth: viewport,
          onPlayheadChanged: (value) => playhead = value,
        ),
      );

      final painter = tester.getRect(find.byType(CustomPaint).last);
      final origin = Offset(painter.left + viewport / 2, painter.center.dy);

      final gesture = await tester.startGesture(origin);
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(playhead, Duration.zero);
    });
  });

  group('transport row fits', () {
    // The reported overflow was an iPhone 13 mini at the system's 1.35x text
    // scale, zoomed in so the range label read "00:08 – 00:24".
    for (final scale in [1.0, 1.3529, 2.0, 3.0]) {
      for (final width in [317.0, 264.0]) {
        testWidgets('no overflow at ${scale}x text on a ${width}px row', (
          tester,
        ) async {
          await tester.pumpWidget(
            _TimelineHarness(
              total: const Duration(seconds: 32),
              initialPlayhead: const Duration(seconds: 16),
              viewportWidth: width,
              textScale: scale,
              onPlayheadChanged: (_) {},
            ),
          );

          // Zoom past 1.01 so the wide "start – end" label is the one shown.
          await tester.tap(find.byIcon(Icons.add));
          await tester.pump();
          await tester.tap(find.byIcon(Icons.add));
          await tester.pump();

          expect(find.textContaining('–'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

class _TimelineHarness extends StatefulWidget {
  const _TimelineHarness({
    required this.total,
    required this.initialPlayhead,
    required this.viewportWidth,
    required this.onPlayheadChanged,
    this.textScale = 1.0,
  });

  final Duration total;
  final Duration initialPlayhead;
  final double viewportWidth;
  final ValueChanged<Duration> onPlayheadChanged;
  final double textScale;

  @override
  State<_TimelineHarness> createState() => _TimelineHarnessState();
}

class _TimelineHarnessState extends State<_TimelineHarness> {
  late Duration _playhead = widget.initialPlayhead;
  late Duration _trimEnd = widget.total;
  Duration _trimStart = Duration.zero;

  @override
  Widget build(BuildContext context) {
    // The card adds 16px of margin and 12px of padding on each side.
    const chrome = 56.0;

    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: widget.viewportWidth + chrome,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
              child: TimelineWidget(
                duration: widget.total,
                trimStart: _trimStart,
                trimEnd: _trimEnd,
                segments: segmentsFromTrim(start: _trimStart, end: _trimEnd),
                overlays: const <TextOverlay>[],
                playhead: _playhead,
                onPlayheadChanged: (value) {
                  setState(() => _playhead = value);
                  widget.onPlayheadChanged(value);
                },
                onTrimStartChanged: (value) =>
                    setState(() => _trimStart = value),
                onTrimEndChanged: (value) => setState(() => _trimEnd = value),
                onOverlayChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }
}
