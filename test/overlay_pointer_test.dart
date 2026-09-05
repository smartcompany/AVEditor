import 'dart:math' as math;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the editor's preview slot: a 9:16 canvas scaled down by [FittedBox],
/// so there is dead space beside the canvas and letterbox inside it.
class _PreviewHarness extends StatefulWidget {
  const _PreviewHarness({
    required this.overlays,
    this.selectedId,
    this.editingId,
    this.onBoxChanged,
    this.onRequestEdit,
    this.onSelected,
    this.onEditingComplete,
    this.onBackgroundTap,
    this.onDeleted,
    this.onDuplicated,
    this.onEdit,
    this.clipRotation = 0,
  });

  final List<TextOverlay> overlays;
  final String? selectedId;
  final String? editingId;
  final OverlayBoxChanged? onBoxChanged;
  final ValueChanged<TextOverlay>? onRequestEdit;
  final ValueChanged<TextOverlay>? onSelected;
  final void Function(String source)? onEditingComplete;
  final VoidCallback? onBackgroundTap;
  final ValueChanged<TextOverlay>? onDeleted;
  final ValueChanged<TextOverlay>? onDuplicated;
  final ValueChanged<TextOverlay>? onEdit;
  final double clipRotation;

  @override
  State<_PreviewHarness> createState() => _PreviewHarnessState();
}

class _PreviewHarnessState extends State<_PreviewHarness> {
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 400,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final targetWidth = constraints.maxWidth;
                return Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (e) =>
                      _previewKey.currentState?.handlePointerDown(e),
                  onPointerMove: (e) =>
                      _previewKey.currentState?.handlePointerMove(e),
                  onPointerUp: (e) =>
                      _previewKey.currentState?.handlePointerUp(e.pointer),
                  onPointerCancel: (e) =>
                      _previewKey.currentState?.handlePointerCancel(e.pointer),
                  child: SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      clipBehavior: Clip.none,
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: targetWidth,
                        height: targetWidth * 16 / 9,
                        child: VideoPreviewWithOverlays(
                          key: _previewKey,
                          videoAspectRatio: 16 / 9,
                          videoChild: const ColoredBox(color: Colors.blue),
                          overlays: widget.overlays,
                          position: const Duration(seconds: 1),
                          selectedOverlayId: widget.selectedId,
                          editingOverlayId: widget.editingId,
                          onOverlayBoxChanged: widget.onBoxChanged,
                          onRequestEdit: widget.onRequestEdit,
                          onOverlaySelected: widget.onSelected,
                          onEditingComplete: widget.onEditingComplete,
                          onBackgroundTap: widget.onBackgroundTap,
                          onOverlayDeleted: widget.onDeleted,
                          onOverlayDuplicated: widget.onDuplicated,
                          onOverlayEdit: widget.onEdit,
                          clipRotation: widget.clipRotation,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Byte-for-byte copy of the editor's preview slot, including the surrounding
/// Scaffold/Column/Expanded/Padding chain, so layout-level pointer regressions
/// show up here instead of on the device.
class _EditorReplica extends StatefulWidget {
  const _EditorReplica({
    required this.overlays,
    required this.videoAspectRatio,
    this.selectedId,
    this.onDeleted,
  });

  final List<TextOverlay> overlays;
  final double videoAspectRatio;
  final String? selectedId;
  final ValueChanged<TextOverlay>? onDeleted;

  @override
  State<_EditorReplica> createState() => _EditorReplicaState();
}

class _EditorReplicaState extends State<_EditorReplica> {
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(title: const Text('Editor')),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final targetWidth = constraints.maxWidth;
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) =>
                          _previewKey.currentState?.handlePointerDown(e),
                      onPointerMove: (e) =>
                          _previewKey.currentState?.handlePointerMove(e),
                      onPointerUp: (e) =>
                          _previewKey.currentState?.handlePointerUp(e.pointer),
                      onPointerCancel: (e) => _previewKey.currentState
                          ?.handlePointerCancel(e.pointer),
                      child: SizedBox.expand(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          clipBehavior: Clip.none,
                          alignment: Alignment.topCenter,
                          child: OverflowSizedBox(
                            width: targetWidth,
                            height: targetWidth * 16 / 9,
                            child: VideoPreviewWithOverlays(
                              key: _previewKey,
                              videoAspectRatio: widget.videoAspectRatio,
                              videoChild: const ColoredBox(color: Colors.blue),
                              overlays: widget.overlays,
                              position: const Duration(seconds: 1),
                              selectedOverlayId: widget.selectedId,
                              onOverlayDeleted: widget.onDeleted,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 120, child: Placeholder()),
            const SizedBox(height: 64, child: Placeholder()),
          ],
        ),
      ),
    );
  }
}

void main() {
  // Sizes are frame pixels. The harness canvas is 360 wide, so a third of the
  // 1080 frame: these values render as a 340x300 box with a 28px font, big
  // enough that the corner handles land in the letterbox and past the edge.
  TextOverlay buildOverlay() => TextOverlay(
        id: 'overlay-1',
        text: 'hello',
        start: Duration.zero,
        end: const Duration(seconds: 5),
        fontSize: 84,
        boxWidth: 1020,
        boxHeight: 900,
      );

  Offset Function(Offset) previewMapper(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(
      find.byType(VideoPreviewWithOverlays),
    );
    return box.localToGlobal;
  }

  /// Resolves an overlay into canvas pixels the way the preview does.
  OverlayBox canvasBox(TextOverlay overlay, RenderBox previewBox) {
    final scale = previewBox.size.width / kOverlayFrameWidth;
    return OverlayBox(
      width: overlay.boxWidth * scale,
      height: overlay.boxHeight * scale,
      fontSize: overlay.fontSize * scale,
      offset: overlay.offset,
      rotation: overlay.rotation,
    );
  }

  // Corner anchors for [buildOverlay] in canvas pixels. The box spans
  // x 10..350, y 170..470 and the handles sit 15px outside each edge.
  const topLeftCorner = Offset(-5, 155);
  const topRightCorner = Offset(365, 155);
  const bottomLeftCorner = Offset(-5, 485);
  const bottomRightCorner = Offset(365, 485);
  const boxCentre = Offset(180, 320);

  testWidgets('resize handle outside the canvas still drives a resize',
      (tester) async {
    final overlay = buildOverlay();
    double? width;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (o, t) => width = t.width,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Bottom-right knob: x is past the canvas width (360), y is in the letterbox.
    final gesture = await tester.startGesture(toGlobal(bottomRightCorner));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(width, isNotNull, reason: 'resize never reached the preview');
    expect(width, greaterThan(overlay.boxWidth));
  });

  testWidgets('resize scales box and font by the same factor', (tester) async {
    final overlay = buildOverlay();
    OverlayTransform? result;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (o, t) => result = t,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Bottom-right knob: scale+rotate; drag out to grow.
    final gesture = await tester.startGesture(toGlobal(bottomRightCorner));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final widthFactor = result!.width / overlay.boxWidth;
    expect(widthFactor, greaterThan(1.05), reason: 'drag should grow the box');
    expect(result!.height / overlay.boxHeight, closeTo(widthFactor, 0.001));
    expect(result!.fontSize / overlay.fontSize, closeTo(widthFactor, 0.001));
  });

  testWidgets('top-right corner opens the edit sheet', (tester) async {
    final overlay = buildOverlay();
    TextOverlay? edited;
    TextOverlay? deleted;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onDeleted: (o) => deleted = o,
        onEdit: (o) => edited = o,
      ),
    );

    await tester.tapAt(previewMapper(tester)(topRightCorner));
    await tester.pump();

    expect(edited?.id, overlay.id);
    expect(deleted, isNull, reason: 'edit must not delete');
  });

  testWidgets('top-left corner deletes the overlay', (tester) async {
    final overlay = buildOverlay();
    TextOverlay? deleted;
    TextOverlay? edited;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onDeleted: (o) => deleted = o,
        onRequestEdit: (o) => edited = o,
      ),
    );

    await tester.tapAt(previewMapper(tester)(topLeftCorner));
    await tester.pump();

    expect(deleted?.id, overlay.id);
    expect(edited, isNull, reason: 'corner taps must not open the editor');
  });

  testWidgets('bottom-left corner duplicates the overlay', (tester) async {
    final overlay = buildOverlay();
    TextOverlay? duplicated;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onDuplicated: (o) => duplicated = o,
      ),
    );

    await tester.tapAt(previewMapper(tester)(bottomLeftCorner));
    await tester.pump();

    expect(duplicated?.id, overlay.id);
  });

  testWidgets('a corner press that travels does not fire its action',
      (tester) async {
    final overlay = buildOverlay();
    TextOverlay? deleted;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onDeleted: (o) => deleted = o,
      ),
    );

    final gesture = await tester.startGesture(
      previewMapper(tester)(topLeftCorner),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(40, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(deleted, isNull);
  });

  testWidgets('dragging the bottom-right corner around rotates the overlay',
      (tester) async {
    final overlay = buildOverlay();
    OverlayTransform? result;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (o, t) => result = t,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Swing the corner a quarter turn clockwise about the centre, keeping its
    // distance so only the angle changes.
    final arm = bottomRightCorner - boxCentre;
    final quarterTurn = boxCentre + Offset(-arm.dy, arm.dx);

    final gesture = await tester.startGesture(toGlobal(bottomRightCorner));
    await tester.pump();
    await gesture.moveTo(toGlobal(quarterTurn));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(result, isNotNull, reason: 'rotate never reached the preview');
    expect(result!.rotation, closeTo(math.pi / 2, 0.01));
    expect(result!.width / overlay.boxWidth, closeTo(1, 0.01),
        reason: 'a pure rotation must not change the size');
  });

  testWidgets('the bottom-right corner still scales along the arm',
      (tester) async {
    final overlay = buildOverlay();
    OverlayTransform? result;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (o, t) => result = t,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Straight out along the centre→corner line: distance grows, angle does not.
    final arm = bottomRightCorner - boxCentre;
    final pulled = boxCentre + arm * 1.2;

    final gesture = await tester.startGesture(toGlobal(bottomRightCorner));
    await tester.pump();
    await gesture.moveTo(toGlobal(pulled));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(result!.rotation, closeTo(0, 0.001));
    expect(result!.width / overlay.boxWidth, closeTo(1.2, 0.01));
    expect(result!.fontSize / overlay.fontSize, closeTo(1.2, 0.01));
  });

  testWidgets('a rotated overlay is hit tested in its own frame',
      (tester) async {
    // Quarter turn: the box's long axis now runs vertically, so a point above
    // the centre falls inside the body while the un-rotated box misses it.
    final overlay = buildOverlay()..rotation = math.pi / 2;
    TextOverlay? selected;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onSelected: (o) => selected = o,
      ),
    );

    final toGlobal = previewMapper(tester);
    await tester.tapAt(toGlobal(boxCentre - const Offset(0, 165)));
    await tester.pump();

    expect(selected?.id, overlay.id);
  });

  testWidgets('a rotated overlay ignores taps outside its rotated body',
      (tester) async {
    final overlay = buildOverlay()..rotation = math.pi / 2;
    TextOverlay? selected;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onSelected: (o) => selected = o,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Inside the un-rotated box, outside the rotated one (now 300 wide).
    await tester.tapAt(toGlobal(boxCentre + const Offset(165, 0)));
    await tester.pump();

    expect(selected, isNull);
  });

  testWidgets('tap on a selected overlay opens the inline editor',
      (tester) async {
    final overlay = buildOverlay();
    TextOverlay? edited;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onRequestEdit: (o) => edited = o,
      ),
    );

    final toGlobal = previewMapper(tester);
    await tester.tapAt(toGlobal(const Offset(180, 320)));
    await tester.pump();

    expect(edited?.id, overlay.id);
  });

  testWidgets('tap on an unselected overlay selects it', (tester) async {
    final overlay = buildOverlay();
    TextOverlay? selected;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onSelected: (o) => selected = o,
      ),
    );

    final toGlobal = previewMapper(tester);
    await tester.tapAt(toGlobal(const Offset(180, 320)));
    await tester.pump();

    expect(selected?.id, overlay.id);
  });

  testWidgets('letterbox tap while editing dismisses the editor',
      (tester) async {
    final overlay = buildOverlay();
    String? source;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        editingId: overlay.id,
        onEditingComplete: (s) => source ??= s,
      ),
    );
    await tester.pump();

    final toGlobal = previewMapper(tester);
    // Below the overlay chrome, inside the black letterbox.
    await tester.tapAt(toGlobal(const Offset(180, 600)));
    await tester.pump();

    expect(source, isNotNull);
  });

  testWidgets('dead space left of the scaled canvas reaches the preview',
      (tester) async {
    // Wide, short window: FittedBox shrinks the 9:16 canvas so a wide black
    // gutter appears on both sides of it — the area the user taps.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Pushed hard left so the left handles land outside the canvas.
    final overlay = buildOverlay()..offset = const Offset(-1, 0);
    TextOverlay? deleted;

    await tester.pumpWidget(
      _EditorReplica(
        overlays: [overlay],
        videoAspectRatio: 16 / 9,
        selectedId: overlay.id,
        onDeleted: (o) => deleted = o,
      ),
    );

    final previewBox = tester.renderObject<RenderBox>(
      find.byType(VideoPreviewWithOverlays),
    );
    expect(
      previewBox.localToGlobal(Offset.zero).dx,
      greaterThan(60),
      reason: 'expected a wide gutter beside the canvas',
    );

    final topLeft = OverlayGeometry.chromeTopLeft(
      previewW: previewBox.size.width,
      previewH: previewBox.size.height,
      box: canvasBox(overlay, previewBox),
    );
    expect(topLeft.dx, lessThan(0), reason: 'handles should overflow the canvas');

    final corners = OverlayGeometry.resolveChromeCorners(
      previewW: previewBox.size.width,
      previewH: previewBox.size.height,
      box: canvasBox(overlay, previewBox),
    );
    final deletePreview = topLeft + corners.delete;
    // Even when the box is shoved left, the delete knob stays on-canvas.
    expect(deletePreview.dx, greaterThanOrEqualTo(0));
    await tester.tapAt(previewBox.localToGlobal(deletePreview));
    await tester.pump();

    expect(deleted?.id, overlay.id,
        reason: 'clamped delete knob should still be tappable');
  });

  testWidgets('tap on empty canvas toggles playback', (tester) async {
    final overlay = buildOverlay();
    var taps = 0;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onBackgroundTap: () => taps++,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Letterbox below the overlay body, which spans y 170..470.
    await tester.tapAt(toGlobal(const Offset(180, 600)));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('tapping an overlay does not toggle playback', (tester) async {
    final overlay = buildOverlay();
    var taps = 0;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onBackgroundTap: () => taps++,
        onSelected: (_) {},
      ),
    );

    final toGlobal = previewMapper(tester);
    await tester.tapAt(toGlobal(const Offset(180, 320)));
    await tester.pump();

    expect(taps, 0);
  });

  testWidgets('dragging the canvas does not toggle playback', (tester) async {
    final overlay = buildOverlay();
    var taps = 0;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        onBackgroundTap: () => taps++,
      ),
    );

    final toGlobal = previewMapper(tester);
    final gesture = await tester.startGesture(toGlobal(const Offset(180, 600)));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
  });

  testWidgets('releasing a resize does not toggle playback', (tester) async {
    final overlay = buildOverlay();
    var taps = 0;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBackgroundTap: () => taps++,
      ),
    );

    final toGlobal = previewMapper(tester);
    // Press the bottom-right knob and release without travelling.
    await tester.tapAt(toGlobal(bottomRightCorner));
    await tester.pump();

    expect(taps, 0);
  });

  testWidgets('tap inside the text field while editing keeps editing',
      (tester) async {
    final overlay = buildOverlay();
    String? source;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        editingId: overlay.id,
        onEditingComplete: (s) => source ??= s,
      ),
    );
    await tester.pump();

    final toGlobal = previewMapper(tester);
    await tester.tapAt(toGlobal(const Offset(180, 320)));
    await tester.pump();

    expect(source, isNull);
  });

  testWidgets('two-finger pinch does not rotate the clip', (tester) async {
    await tester.pumpWidget(
      const _PreviewHarness(overlays: []),
    );

    final toGlobal = previewMapper(tester);
    final fingerA = toGlobal(const Offset(100, 320));
    final fingerB = toGlobal(const Offset(260, 320));
    final turned = toGlobal(const Offset(100, 480));

    final g1 = await tester.startGesture(fingerA);
    final g2 = await tester.startGesture(fingerB);
    await tester.pump();
    await g2.moveTo(turned);
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pump();

    final preview = tester.widget<VideoPreviewWithOverlays>(
      find.byType(VideoPreviewWithOverlays),
    );
    expect(preview.clipRotation, 0);
  });

  testWidgets('a second finger cancels an in-progress overlay resize',
      (tester) async {
    final overlay = buildOverlay();
    OverlayTransform? committed;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (o, t) => committed = t,
      ),
    );

    final toGlobal = previewMapper(tester);
    final resize = await tester.startGesture(toGlobal(bottomRightCorner));
    await tester.pump();
    await resize.moveBy(const Offset(20, 20));
    await tester.pump();

    final twist = await tester.startGesture(toGlobal(const Offset(200, 500)));
    await tester.pump();
    await resize.up();
    await twist.up();
    await tester.pump();

    expect(committed, isNull,
        reason: 'pinch should abandon the resize without committing');
  });

  testWidgets('the preview background uses cover fit like export',
      (tester) async {
    await tester.pumpWidget(
      _PreviewHarness(overlays: []),
    );

    final fitted = tester.widget<FittedBox>(
      find.descendant(
        of: find.byType(VideoPreviewWithOverlays),
        matching: find.byType(FittedBox),
      ),
    );
    expect(fitted.fit, BoxFit.cover);
  });
}
