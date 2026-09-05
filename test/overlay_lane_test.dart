import 'package:aveditor/models/text_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overlapping text overlays are assigned a new lane', () {
    final a = TextOverlay(
      id: 'a',
      text: 'A',
      start: Duration.zero,
      end: const Duration(seconds: 10),
      lane: 0,
    );
    final b = TextOverlay(
      id: 'b',
      text: 'B',
      start: const Duration(seconds: 4),
      end: const Duration(seconds: 14),
      lane: 0,
    );

    final placed = assignOverlayLane([a], b);
    expect(placed.lane, 1);
    expect(overlayLaneCount([a, placed]), 2);
  });

  test('non-overlapping text packs up onto the free upper lane', () {
    final a = TextOverlay(
      id: 'a',
      text: 'A',
      start: Duration.zero,
      end: const Duration(seconds: 4),
      lane: 0,
    );
    final b = TextOverlay(
      id: 'b',
      text: 'B',
      start: const Duration(seconds: 10),
      end: const Duration(seconds: 14),
      lane: 1,
    );

    final placed = assignOverlayLane([a], b);
    expect(placed.lane, 0);
  });

  test('split piece moved into a gap packs back onto the upper lane', () {
    final top = TextOverlay(
      id: 'top',
      text: 'Top',
      start: Duration.zero,
      end: const Duration(seconds: 8),
      lane: 0,
    );
    final left = TextOverlay(
      id: 'left',
      text: 'Bottom',
      start: Duration.zero,
      end: const Duration(seconds: 3),
      lane: 1,
    );
    final right = TextOverlay(
      id: 'right',
      text: 'Bottom',
      start: const Duration(seconds: 3),
      end: const Duration(seconds: 6),
      lane: 1,
    );

    // Drag the split right-hand piece clear of the top clip — rises to lane 0.
    final moved = right.copyWith(
      start: const Duration(seconds: 10),
      end: const Duration(seconds: 13),
    );
    final placed = assignOverlayLane([top, left], moved);
    expect(placed.lane, 0);
  });

  test('sticky mode keeps the lower lane when preferLowestLane is false', () {
    final top = TextOverlay(
      id: 'top',
      text: 'Top',
      start: Duration.zero,
      end: const Duration(seconds: 8),
      lane: 0,
    );
    final moved = TextOverlay(
      id: 'right',
      text: 'Bottom',
      start: const Duration(seconds: 10),
      end: const Duration(seconds: 13),
      lane: 1,
    );

    final placed = assignOverlayLane(
      [top],
      moved,
      preferLowestLane: false,
    );
    expect(placed.lane, 1);
  });

  test('overlap on current lane opens a lane below when upper is full', () {
    final top = TextOverlay(
      id: 'top',
      text: 'Top',
      start: Duration.zero,
      end: const Duration(seconds: 10),
      lane: 0,
    );
    final bottom = TextOverlay(
      id: 'bottom',
      text: 'Bottom',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 5),
      lane: 1,
    );
    // Move bottom onto another clip that is also on lane 1.
    final sibling = TextOverlay(
      id: 'sibling',
      text: 'Sibling',
      start: const Duration(seconds: 4),
      end: const Duration(seconds: 8),
      lane: 1,
    );

    final placed = assignOverlayLane([top, sibling], bottom);
    expect(placed.lane, 2);
  });

  test('resolveOverlayLanes packs legacy one-per-row projects', () {
    final overlays = [
      TextOverlay(
        id: 'a',
        text: 'A',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        lane: 0,
      ),
      TextOverlay(
        id: 'b',
        text: 'B',
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 7),
        lane: 1,
      ),
      TextOverlay(
        id: 'c',
        text: 'C',
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 6),
        lane: 2,
      ),
    ];

    final packed = resolveOverlayLanes(overlays);
    expect(packed.firstWhere((o) => o.id == 'a').lane, 0);
    // b does not overlap a → packs onto lane 0.
    expect(packed.firstWhere((o) => o.id == 'b').lane, 0);
    // c overlaps both → needs lane 1.
    expect(packed.firstWhere((o) => o.id == 'c').lane, 1);
    expect(overlayLaneCount(packed), 2);
  });

  test('lane survives json round-trip', () {
    final overlay = TextOverlay(
      text: 'Lane',
      start: Duration.zero,
      end: const Duration(seconds: 1),
      lane: 2,
    );
    final restored = TextOverlay.fromJson(overlay.toJson());
    expect(restored.lane, 2);
  });

  test('splitTextOverlay cuts at playhead and keeps both on same lane', () {
    final overlay = TextOverlay(
      id: 'o1',
      text: 'Hello',
      start: Duration.zero,
      end: const Duration(seconds: 4),
      lane: 0,
    );

    final split = splitTextOverlay(overlay, const Duration(seconds: 2));
    expect(split, isNotNull);
    expect(split!.$1.id, 'o1');
    expect(split.$1.end, const Duration(seconds: 2));
    expect(split.$2.id, isNot('o1'));
    expect(split.$2.start, const Duration(seconds: 2));
    expect(split.$2.end, const Duration(seconds: 4));
    expect(split.$2.text, 'Hello');
    expect(split.$1.lane, 0);
    expect(split.$2.lane, 0);
    expect(overlayRangesOverlap(split.$1, split.$2), isFalse);
  });

  test('new text prefers oldest free lane before opening another', () {
    final early = TextOverlay(
      id: 'early',
      text: 'Early',
      start: Duration.zero,
      end: const Duration(seconds: 3),
      lane: 0,
    );
    final lower = TextOverlay(
      id: 'lower',
      text: 'Lower',
      start: Duration.zero,
      end: const Duration(seconds: 3),
      lane: 1,
    );
    // Playhead past both — lane 0 has room first.
    final next = TextOverlay(
      id: 'next',
      text: 'Next',
      start: const Duration(seconds: 4),
      end: const Duration(seconds: 7),
      lane: 0,
    );

    final placed = assignOverlayLane(
      [early, lower],
      next,
      preferLowestLane: true,
    );
    expect(placed.lane, 0);
  });

  test('new text opens a lane only when every existing lane conflicts', () {
    final a = TextOverlay(
      id: 'a',
      text: 'A',
      start: Duration.zero,
      end: const Duration(seconds: 5),
      lane: 0,
    );
    final b = TextOverlay(
      id: 'b',
      text: 'B',
      start: Duration.zero,
      end: const Duration(seconds: 5),
      lane: 1,
    );
    final next = TextOverlay(
      id: 'next',
      text: 'Next',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 5),
      lane: 0,
    );

    final placed = assignOverlayLane(
      [a, b],
      next,
      preferLowestLane: true,
    );
    expect(placed.lane, 2);
  });
}
