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
  });

  final List<TextOverlay> overlays;
  final String? selectedId;
  final String? editingId;
  final void Function(TextOverlay, double, double, Offset)? onBoxChanged;
  final ValueChanged<TextOverlay>? onRequestEdit;
  final ValueChanged<TextOverlay>? onSelected;
  final void Function(String source)? onEditingComplete;

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
    this.onBoxChanged,
  });

  final List<TextOverlay> overlays;
  final double videoAspectRatio;
  final String? selectedId;
  final void Function(TextOverlay, double, double, Offset)? onBoxChanged;

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
                              onOverlayBoxChanged: widget.onBoxChanged,
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
  // Wide/tall enough that the corner handles land in the letterbox and past the
  // right edge of the 9:16 canvas — the case that used to swallow pointers.
  TextOverlay buildOverlay() => TextOverlay(
        id: 'overlay-1',
        text: 'hello',
        start: Duration.zero,
        end: const Duration(seconds: 5),
        boxWidth: 340,
        boxHeight: 300,
      );

  Offset Function(Offset) previewMapper(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(
      find.byType(VideoPreviewWithOverlays),
    );
    return box.localToGlobal;
  }

  testWidgets('resize handle outside the canvas still drives a resize',
      (tester) async {
    final overlay = buildOverlay();
    double? width;
    double? height;

    await tester.pumpWidget(
      _PreviewHarness(
        overlays: [overlay],
        selectedId: overlay.id,
        onBoxChanged: (overlay, w, h, offset) {
          width = w;
          height = h;
        },
      ),
    );

    final toGlobal = previewMapper(tester);
    // Bottom-right knob: x is past the canvas width (360), y is in the letterbox.
    final gesture = await tester.startGesture(toGlobal(const Offset(365, 485)));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // The canvas is scaled to 0.625, so a 30px screen drag is 48 preview px.
    expect(width, isNotNull, reason: 'resize never reached the preview');
    expect(width, closeTo(388, 0.5));
    expect(height, closeTo(348, 0.5));
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
    double? width;

    await tester.pumpWidget(
      _EditorReplica(
        overlays: [overlay],
        videoAspectRatio: 16 / 9,
        selectedId: overlay.id,
        onBoxChanged: (o, w, h, offset) => width = w,
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
      overlay: overlay,
    );
    expect(topLeft.dx, lessThan(0), reason: 'handles should overflow the canvas');

    const knobInset =
        OverlayGeometry.handlePad - OverlayGeometry.knobOutset + OverlayGeometry.knobSize / 2;
    final knobLocal = topLeft + const Offset(knobInset, knobInset);
    final gesture = await tester.startGesture(previewBox.localToGlobal(knobLocal));
    await tester.pump();
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(width, isNotNull, reason: 'gutter tap never reached the preview');
    expect(width, greaterThan(overlay.boxWidth));
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
}
