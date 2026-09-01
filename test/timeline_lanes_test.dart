import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const total = Duration(seconds: 30);
  const viewport = 400.0;

  // Mirrors the private layout constants in timeline_widget.dart. If these
  // drift the geometry assertions below will fail loudly rather than silently.
  const videoTrackHeight = 58.0;
  const laneHeight = 26.0;
  const laneStride = 30.0;
  const maxVisibleLanes = 3;

  double laneCentreY(int index, {double scrollY = 0}) =>
      videoTrackHeight + index * laneStride + laneHeight / 2 - scrollY;

  List<TextOverlay> layers(int count) => [
    for (var i = 0; i < count; i++)
      TextOverlay(
        id: 'layer-$i',
        text: 'Layer $i',
        start: Duration.zero,
        end: total,
      ),
  ];

  /// The timeline's painted body, excluding the transport row above it.
  Finder bodyFinder() => find.byWidgetPredicate(
    (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_TimelinePainter',
  );

  Future<void> pumpTimeline(
    WidgetTester tester, {
    required List<TextOverlay> overlays,
    String? selectedId,
    ValueChanged<TextOverlay>? onSelected,
    ValueChanged<Duration>? onPlayheadChanged,
    ValueChanged<TextOverlay>? onOverlayChanged,
  }) {
    return tester.pumpWidget(
      _LaneHarness(
        total: total,
        viewportWidth: viewport,
        overlays: overlays,
        selectedId: selectedId,
        onSelected: onSelected,
        onPlayheadChanged: onPlayheadChanged,
        onOverlayChanged: onOverlayChanged,
      ),
    );
  }

  group('one lane per layer', () {
    testWidgets('each added layer gets its own row', (tester) async {
      final overlays = layers(3);
      final selected = <String>[];

      await pumpTimeline(
        tester,
        overlays: overlays,
        onSelected: (o) => selected.add(o.id),
      );

      final body = tester.getRect(bodyFinder());
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(
          Offset(body.left + viewport / 2, body.top + laneCentreY(i)),
        );
        await tester.pump();
      }

      expect(selected, ['layer-0', 'layer-1', 'layer-2']);
    });

    testWidgets('the body grows per layer, then caps and scrolls',
        (tester) async {
      for (final count in [1, 2, 3]) {
        await pumpTimeline(tester, overlays: layers(count));
        expect(
          tester.getRect(bodyFinder()).height,
          videoTrackHeight + count * laneStride,
          reason: '$count layers',
        );
      }

      await pumpTimeline(tester, overlays: layers(6));
      expect(
        tester.getRect(bodyFinder()).height,
        videoTrackHeight + maxVisibleLanes * laneStride,
      );
    });

    testWidgets('an empty timeline still shows one lane slot', (tester) async {
      await pumpTimeline(tester, overlays: const []);

      expect(
        tester.getRect(bodyFinder()).height,
        videoTrackHeight + laneStride,
      );
    });
  });

  group('lane scrolling', () {
    testWidgets('a hidden layer is reachable after scrolling', (tester) async {
      final selected = <String>[];
      await pumpTimeline(
        tester,
        overlays: layers(6),
        onSelected: (o) => selected.add(o.id),
      );

      final body = tester.getRect(bodyFinder());
      // Lane 5 sits below the 3-lane viewport, so it cannot be hit yet.
      final belowFold = body.top + laneCentreY(5);
      expect(belowFold, greaterThan(body.bottom));

      // Drag up by the full scrollable extent: 6 lanes of content, 3 visible.
      const maxScroll = (6 - maxVisibleLanes) * laneStride;
      await tester.drag(
        bodyFinder(),
        const Offset(0, -maxScroll),
        warnIfMissed: false,
      );
      await tester.pump();

      await tester.tapAt(
        Offset(
          body.left + viewport / 2,
          body.top + laneCentreY(5, scrollY: maxScroll),
        ),
      );
      await tester.pump();

      expect(selected.last, 'layer-5');
    });

    testWidgets('scrolling lanes does not move the playhead', (tester) async {
      final seeks = <Duration>[];
      await pumpTimeline(
        tester,
        overlays: layers(6),
        onPlayheadChanged: seeks.add,
      );

      await tester.drag(
        bodyFinder(),
        const Offset(0, -60),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(seeks, isEmpty);
    });

    testWidgets('a vertical swipe on a layer bar scrolls instead of moving it',
        (tester) async {
      // Bars packed edge to edge leave no empty strip to start a scroll from,
      // so the bars themselves have to yield to a vertical swipe.
      final moved = <TextOverlay>[];
      final selected = <String>[];
      await pumpTimeline(
        tester,
        overlays: layers(6),
        onSelected: (o) => selected.add(o.id),
        onOverlayChanged: moved.add,
      );

      final body = tester.getRect(bodyFinder());
      const maxScroll = (6 - maxVisibleLanes) * laneStride;

      await tester.drag(
        bodyFinder(),
        const Offset(0, -maxScroll),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(moved, isEmpty, reason: 'the swipe must not retime a layer');
      expect(selected, isEmpty, reason: 'scrolling must not change selection');

      await tester.tapAt(
        Offset(
          body.left + viewport / 2,
          body.top + laneCentreY(5, scrollY: maxScroll),
        ),
      );
      await tester.pump();

      expect(selected.last, 'layer-5');
    });

    testWidgets('a horizontal drag on a layer bar still retimes it',
        (tester) async {
      final moved = <TextOverlay>[];
      await pumpTimeline(
        tester,
        overlays: layers(6),
        onOverlayChanged: moved.add,
      );

      await tester.drag(
        bodyFinder(),
        const Offset(-40, 0),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(moved, isNotEmpty);
    });

    testWidgets('selecting a layer scrolls it into view', (tester) async {
      final overlays = layers(6);
      await pumpTimeline(tester, overlays: overlays);

      final body = tester.getRect(bodyFinder());
      final selected = <String>[];

      // Rebuild with the last layer selected, as adding text does.
      await pumpTimeline(
        tester,
        overlays: overlays,
        selectedId: 'layer-5',
        onSelected: (o) => selected.add(o.id),
      );

      const maxScroll = (6 - maxVisibleLanes) * laneStride;
      await tester.tapAt(
        Offset(
          body.left + viewport / 2,
          body.top + laneCentreY(5, scrollY: maxScroll),
        ),
      );
      await tester.pump();

      expect(selected.last, 'layer-5');
    });
  });
}

class _LaneHarness extends StatelessWidget {
  const _LaneHarness({
    required this.total,
    required this.viewportWidth,
    required this.overlays,
    this.selectedId,
    this.onSelected,
    this.onPlayheadChanged,
    this.onOverlayChanged,
  });

  final Duration total;
  final double viewportWidth;
  final List<TextOverlay> overlays;
  final String? selectedId;
  final ValueChanged<TextOverlay>? onSelected;
  final ValueChanged<Duration>? onPlayheadChanged;
  final ValueChanged<TextOverlay>? onOverlayChanged;

  @override
  Widget build(BuildContext context) {
    // The card adds 16px of margin and 12px of padding on each side.
    const chrome = 56.0;

    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: viewportWidth + chrome,
            child: TimelineWidget(
              duration: total,
              trimStart: Duration.zero,
              trimEnd: total,
              segments: segmentsFromTrim(start: Duration.zero, end: total),
              overlays: overlays,
              playhead: const Duration(seconds: 15),
              selectedOverlayId: selectedId,
              onOverlaySelected: onSelected,
              onPlayheadChanged: onPlayheadChanged ?? (_) {},
              onTrimStartChanged: (_) {},
              onTrimEndChanged: (_) {},
              onOverlayChanged: onOverlayChanged ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }
}
