import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:flutter/material.dart';

export 'overlay_geometry.dart' show OverlayGeometry;

const double minOverlayFontSize = 16;
const double maxOverlayFontSize = 64;
const double minOverlayBoxWidth = 64;
const double minOverlayBoxHeight = 48;
/// Fallback caps; overlays use [VideoPreviewWithOverlays] layout size when available.
const double maxOverlayBoxWidth = 800;
const double maxOverlayBoxHeight = 900;
/// Normalized offset from center — allows placing boxes into letterbox / past edges.
const double maxOverlayOffset = 3.5;

/// 9:16 preview with time-bound, draggable text overlays.
class VideoPreviewWithOverlays extends StatefulWidget {
  const VideoPreviewWithOverlays({
    super.key,
    required this.videoChild,
    required this.videoAspectRatio,
    required this.overlays,
    required this.position,
    this.selectedOverlayId,
    this.editingOverlayId,
    this.textHint,
    this.onOverlayOffsetChanged,
    this.onOverlayBoxChanged,
    this.onOverlaySelected,
    this.onOverlayTextChanged,
    this.onEditingComplete,
    this.onRequestEdit,
  });

  final Widget videoChild;
  final double videoAspectRatio;
  final List<TextOverlay> overlays;
  final Duration position;
  final String? selectedOverlayId;
  final String? editingOverlayId;
  final String? textHint;
  final void Function(TextOverlay overlay, Offset offset)? onOverlayOffsetChanged;
  final void Function(
    TextOverlay overlay,
    double width,
    double height,
    Offset offset,
  )? onOverlayBoxChanged;
  final ValueChanged<TextOverlay>? onOverlaySelected;
  final void Function(TextOverlay overlay, String text)? onOverlayTextChanged;
  final void Function(String source)? onEditingComplete;
  final ValueChanged<TextOverlay>? onRequestEdit;

  @override
  State<VideoPreviewWithOverlays> createState() =>
      VideoPreviewWithOverlaysState();
}

/// Public state for [GlobalKey] pointer routing from [EditorScreen].
class VideoPreviewWithOverlaysState extends State<VideoPreviewWithOverlays> {
  /// Travel below this stays a tap instead of becoming a drag.
  static const _tapSlop = 4.0;

  OverlayDrag? _activeDrag;
  int? _activePointer;
  TextOverlay? _tapTarget;
  Offset? _lastLocal;
  bool _pointerMoved = false;
  double _pointerTravel = 0;
  int _moveLogCounter = 0;
  double? _liveWidth;
  double? _liveHeight;
  Offset? _liveOffset;
  double? _resizeStartWidth;
  double? _resizeStartHeight;
  Offset? _resizeStartOffset;
  Offset _resizeAccumulated = Offset.zero;
  double _previewW = 0;
  double _previewH = 0;
  double _maxBoxW = 0;
  double _maxBoxH = 0;

  TextOverlay? _overlayById(String? id) {
    if (id == null) return null;
    for (final overlay in widget.overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  TextOverlay? get _selectedOverlay => _overlayById(widget.selectedOverlayId);

  TextOverlay? get _editingOverlay => _overlayById(widget.editingOverlayId);

  List<TextOverlay> get _visibleOverlays => widget.overlays
      .where((o) => o.isVisibleAt(widget.position))
      .toList(growable: false);

  void _clearLiveGeometry() {
    _liveWidth = null;
    _liveHeight = null;
    _liveOffset = null;
  }

  void _clearDragState() {
    _activeDrag = null;
    _activePointer = null;
    _tapTarget = null;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
    _moveLogCounter = 0;
    _resizeStartWidth = null;
    _resizeStartHeight = null;
    _resizeStartOffset = null;
    _resizeAccumulated = Offset.zero;
    _clearLiveGeometry();
  }

  @override
  void didUpdateWidget(covariant VideoPreviewWithOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editingOverlayId != null && widget.editingOverlayId == null) {
      _clearDragState();
    }
    if (oldWidget.selectedOverlayId != widget.selectedOverlayId &&
        _activePointer == null) {
      _clearLiveGeometry();
    }
  }

  double _boxWidth(TextOverlay overlay) =>
      _liveWidth ?? overlay.boxWidth;

  double _boxHeight(TextOverlay overlay) =>
      _liveHeight ?? overlay.boxHeight;

  Offset _boxOffset(TextOverlay overlay) =>
      _liveOffset ?? overlay.offset;

  void _moveBy(TextOverlay overlay, Offset delta) {
    final current = _boxOffset(overlay);
    final nextDx = (current.dx + delta.dx / (_previewW / 2))
        .clamp(-maxOverlayOffset, maxOverlayOffset);
    final nextDy = (current.dy + delta.dy / (_previewH / 2))
        .clamp(-maxOverlayOffset, maxOverlayOffset);
    setState(() => _liveOffset = Offset(nextDx, nextDy));
  }

  void _resizeBy(
    TextOverlay overlay, {
    required Offset delta,
    required bool fromLeft,
    required bool fromTop,
    required double maxBoxW,
    required double maxBoxH,
    required double previewW,
    required double previewH,
  }) {
    _resizeAccumulated += delta;
    final startW = _resizeStartWidth ?? overlay.boxWidth;
    final startH = _resizeStartHeight ?? overlay.boxHeight;
    final startOffset = _resizeStartOffset ?? overlay.offset;
    _resizeStartWidth ??= startW;
    _resizeStartHeight ??= startH;
    _resizeStartOffset ??= startOffset;

    final outwardW = fromLeft ? -_resizeAccumulated.dx : _resizeAccumulated.dx;
    final outwardH = fromTop ? -_resizeAccumulated.dy : _resizeAccumulated.dy;

    final nextW = (startW + outwardW).clamp(minOverlayBoxWidth, maxBoxW);
    final nextH = (startH + outwardH).clamp(minOverlayBoxHeight, maxBoxH);

    final appliedW = nextW - startW;
    final appliedH = nextH - startH;
    final signX = fromLeft ? -1.0 : 1.0;
    final signY = fromTop ? -1.0 : 1.0;
    final nextOffset = Offset(
      (startOffset.dx + signX * appliedW / previewW)
          .clamp(-maxOverlayOffset, maxOverlayOffset),
      (startOffset.dy + signY * appliedH / previewH)
          .clamp(-maxOverlayOffset, maxOverlayOffset),
    );

    setState(() {
      _liveWidth = nextW;
      _liveHeight = nextH;
      _liveOffset = nextOffset;
    });
  }

  void _beginDrag(TextOverlay overlay, OverlayDrag drag) {
    OverlayEventLog.log('PreviewDrag', 'dragBegin', {
      'id': overlay.id.substring(0, 8),
      'drag': drag.label,
      'boxW': _boxWidth(overlay),
      'boxH': _boxHeight(overlay),
    });
    _activeDrag = drag;
    if (drag.isResize) {
      _resizeStartWidth = _boxWidth(overlay);
      _resizeStartHeight = _boxHeight(overlay);
      _resizeStartOffset = _boxOffset(overlay);
      _resizeAccumulated = Offset.zero;
    }
  }

  void _commitDrag(TextOverlay overlay, bool moved) {
    final drag = _activeDrag;
    if (!moved || drag == null) return;

    final w = _boxWidth(overlay);
    final h = _boxHeight(overlay);
    final o = _boxOffset(overlay);
    OverlayEventLog.log('PreviewDrag', 'commitGeometry', {
      'id': overlay.id.substring(0, 8),
      'drag': drag.label,
      'boxW': w,
      'boxH': h,
      'offset': o,
    });
    if (drag.isResize) {
      widget.onOverlayBoxChanged?.call(overlay, w, h, o);
    } else {
      widget.onOverlayOffsetChanged?.call(overlay, o);
    }
    _clearLiveGeometry();
  }

  TextOverlay? _topmostBodyAt(Offset local) {
    for (final overlay in _visibleOverlays.reversed) {
      final isSelected = overlay.id == widget.selectedOverlayId;
      final body = OverlayGeometry.bodyRect(
        previewW: _previewW,
        previewH: _previewH,
        overlay: overlay,
        liveW: isSelected ? _liveWidth : null,
        liveH: isSelected ? _liveHeight : null,
        liveOffset: isSelected ? _liveOffset : null,
      );
      if (body.contains(local)) return overlay;
    }
    return null;
  }

  /// Single pointer entry point — the editor shell forwards every pointer in
  /// the preview slot here, including taps beside/outside the 9:16 canvas.
  void handlePointerDown(PointerDownEvent event) {
    final local = _toPreviewLocal(event);
    OverlayEventLog.log('PreviewCanvas', 'pointerDown', {
      'local': local,
      'pointer': event.pointer,
      'previewW': _previewW,
      'previewH': _previewH,
      'selectedId': widget.selectedOverlayId,
      'editingId': widget.editingOverlayId,
    });
    if (local == null) return;

    final editing = _editingOverlay;
    if (editing != null) {
      final chrome = OverlayGeometry.chromeRect(
        previewW: _previewW,
        previewH: _previewH,
        overlay: editing,
      );
      if (chrome.contains(local)) return;
      OverlayEventLog.log('PreviewCanvas', 'dismissEditing', {'local': local});
      widget.onEditingComplete?.call('preview_outside');
      return;
    }

    if (_activePointer != null) return;

    final selected = _selectedOverlay;
    if (selected != null) {
      final drag = OverlayGeometry.hitTestPreviewPoint(
        local,
        previewW: _previewW,
        previewH: _previewH,
        overlay: selected,
        editing: false,
        liveW: _liveWidth,
        liveH: _liveHeight,
        liveOffset: _liveOffset,
      );
      if (drag != null) {
        OverlayEventLog.log('PreviewCanvas', 'dragStart', {
          'local': local,
          'drag': drag.label,
        });
        _activePointer = event.pointer;
        _lastLocal = local;
        _pointerMoved = false;
        _pointerTravel = 0;
        _moveLogCounter = 0;
        // A body press that never travels is a tap → open the inline editor.
        _tapTarget = drag.isResize ? null : selected;
        _beginDrag(selected, drag);
        return;
      }
    }

    final tapped = _topmostBodyAt(local);
    OverlayEventLog.log('PreviewCanvas', 'bodyProbe', {
      'local': local,
      'hit': tapped?.id,
    });
    if (tapped == null) return;
    _activePointer = event.pointer;
    _lastLocal = local;
    _pointerMoved = false;
    _pointerTravel = 0;
    _tapTarget = tapped;
  }

  void handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    _pointerTravel += event.delta.distance;
    if (_pointerTravel > _tapSlop) _pointerMoved = true;
    final overlay = _selectedOverlay;
    if (overlay == null || _activeDrag == null) return;
    _onPreviewPointerMoveAt(event, overlay);
  }

  void handlePointerUp(int pointer) {
    if (pointer != _activePointer) return;
    final target = _tapTarget;
    final moved = _pointerMoved;
    final drag = _activeDrag;

    if (drag != null) {
      final overlay = _selectedOverlay;
      if (overlay != null) {
        _onPreviewPointerEnd(overlay, pointer);
      }
    }

    _activePointer = null;
    _tapTarget = null;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;

    if (moved || target == null) return;

    if (target.id == widget.selectedOverlayId) {
      OverlayEventLog.log('PreviewCanvas', 'tapRequestEdit', {'id': target.id});
      widget.onRequestEdit?.call(target);
    } else {
      OverlayEventLog.log('PreviewCanvas', 'tapSelect', {'id': target.id});
      widget.onOverlaySelected?.call(target);
    }
  }

  void handlePointerCancel(int pointer) {
    if (pointer != _activePointer) return;
    final overlay = _selectedOverlay;
    if (overlay != null && _activeDrag != null) {
      _onPreviewPointerEnd(overlay, pointer);
    }
    _activePointer = null;
    _tapTarget = null;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
  }

  Offset? _toPreviewLocal(PointerEvent event) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(event.position);
  }

  void _onPreviewPointerMoveAt(
    PointerMoveEvent event,
    TextOverlay overlay,
  ) {
    if (event.pointer != _activePointer || _activeDrag == null) return;

    // Deltas are measured in preview coordinates, not screen pixels: the editor
    // scales the canvas down with a FittedBox, so raw deltas move too slowly.
    final local = _toPreviewLocal(event);
    final last = _lastLocal;
    if (local == null || last == null) return;
    final delta = local - last;
    _lastLocal = local;
    if (delta == Offset.zero) return;

    _moveLogCounter++;
    if (_moveLogCounter == 1 || _moveLogCounter % 12 == 0) {
      OverlayEventLog.log('PreviewDrag', 'pointerMove', {
        'pointer': event.pointer,
        'delta': delta,
        'drag': _activeDrag!.label,
        'count': _moveLogCounter,
      });
    }

    final drag = _activeDrag!;
    if (drag.kind == OverlayDragKind.move) {
      _moveBy(overlay, delta);
    } else {
      _resizeBy(
        overlay,
        delta: delta,
        fromLeft: drag.fromLeft!,
        fromTop: drag.fromTop!,
        maxBoxW: _maxBoxW,
        maxBoxH: _maxBoxH,
        previewW: _previewW,
        previewH: _previewH,
      );
    }
  }

  void _onPreviewPointerEnd(TextOverlay overlay, int pointer) {
    if (pointer != _activePointer) return;
    final moved = _pointerMoved;
    OverlayEventLog.log('PreviewDrag', 'pointerUp', {
      'pointer': pointer,
      'moved': moved,
      'moveCount': _moveLogCounter,
    });
    _commitDrag(overlay, moved);
    if (!moved && _liveWidth != null) {
      setState(_clearLiveGeometry);
    }
    _activeDrag = null;
    _activePointer = null;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
    _moveLogCounter = 0;
    _resizeStartWidth = null;
    _resizeStartHeight = null;
    _resizeStartOffset = null;
    _resizeAccumulated = Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleOverlays;

    return OverflowHitBox(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _previewW = constraints.maxWidth;
            _previewH = constraints.maxHeight;
            _maxBoxW = _previewW + 96;
            _maxBoxH = _previewH + 96;

            return OverflowHitStack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: _VideoCanvasBackground(
                    videoAspectRatio: widget.videoAspectRatio,
                    videoChild: widget.videoChild,
                  ),
                ),
                ...visible.map(
                  (overlay) {
                    final isSelected = overlay.id == widget.selectedOverlayId;
                    return _DraggableOverlayLabel(
                      key: ValueKey(overlay.id),
                      overlay: overlay,
                      previewWidth: _previewW,
                      previewHeight: _previewH,
                      maxBoxWidth: _maxBoxW,
                      maxBoxHeight: _maxBoxH,
                      selected: isSelected,
                      editing: overlay.id == widget.editingOverlayId,
                      textHint: widget.textHint,
                      liveWidth: isSelected ? _liveWidth : null,
                      liveHeight: isSelected ? _liveHeight : null,
                      liveOffset: isSelected ? _liveOffset : null,
                      onTextChanged: (text) =>
                          widget.onOverlayTextChanged?.call(overlay, text),
                      onEditingComplete: widget.onEditingComplete,
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DraggableOverlayLabel extends StatefulWidget {
  const _DraggableOverlayLabel({
    super.key,
    required this.overlay,
    required this.previewWidth,
    required this.previewHeight,
    required this.maxBoxWidth,
    required this.maxBoxHeight,
    required this.selected,
    required this.editing,
    required this.onTextChanged,
    this.onEditingComplete,
    this.textHint,
    this.liveWidth,
    this.liveHeight,
    this.liveOffset,
  });

  final TextOverlay overlay;
  final double previewWidth;
  final double previewHeight;
  final double maxBoxWidth;
  final double maxBoxHeight;
  final bool selected;
  final bool editing;
  final String? textHint;
  final double? liveWidth;
  final double? liveHeight;
  final Offset? liveOffset;
  final ValueChanged<String> onTextChanged;
  final void Function(String source)? onEditingComplete;

  @override
  State<_DraggableOverlayLabel> createState() => _DraggableOverlayLabelState();
}

class _DraggableOverlayLabelState extends State<_DraggableOverlayLabel> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  static const _logTag = 'OverlayLabel';

  String get _overlayIdShort =>
      widget.overlay.id.length <= 8
          ? widget.overlay.id
          : widget.overlay.id.substring(0, 8);

  void _log(String event, [Map<String, Object?>? data]) {
    OverlayEventLog.log(_logTag, event, {
      'id': _overlayIdShort,
      'selected': widget.selected,
      'editing': widget.editing,
      'focus': _focusNode.hasFocus,
      ...?data,
    });
  }

  double get _boxWidth =>
      widget.liveWidth ?? widget.overlay.boxWidth;

  double get _boxHeight =>
      widget.liveHeight ?? widget.overlay.boxHeight;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.overlay.text);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChangedForRebuild);
    if (widget.editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  void _onFocusChangedForRebuild() {
    _log('focusChanged', {'hasFocus': _focusNode.hasFocus});
  }

  @override
  void didUpdateWidget(covariant _DraggableOverlayLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing && !widget.editing) {
      _log('editingEnded');
    }
    if (!oldWidget.editing && widget.editing) {
      _log('editingStarted');
    }
    if (!widget.editing && _controller.text != widget.overlay.text) {
      _controller.text = widget.overlay.text;
    }
    if (widget.editing && !oldWidget.editing) {
      _controller.text = widget.overlay.text;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
          _controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _controller.text.length,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChangedForRebuild);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  TextStyle get _textStyle => TextStyle(
        color: widget.overlay.color,
        fontSize: widget.overlay.fontSize,
        fontWeight: FontWeight.w700,
        shadows: const [
          Shadow(blurRadius: 8, color: Colors.black54),
        ],
      );

  Widget _buildBody() {
    final textWidget = widget.editing
        ? TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.center,
            textAlign: TextAlign.center,
            style: _textStyle,
            cursorColor: AppTheme.accent,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: widget.textHint,
              hintStyle: _textStyle.copyWith(
                color: widget.overlay.color.withValues(alpha: 0.45),
              ),
            ),
            onChanged: widget.onTextChanged,
            onEditingComplete: () =>
                widget.onEditingComplete?.call('textfield_done'),
            onSubmitted: (_) =>
                widget.onEditingComplete?.call('textfield_submit'),
          )
        : Text(
            widget.overlay.text.isEmpty
                ? (widget.textHint ?? '')
                : widget.overlay.text,
            textAlign: TextAlign.center,
            maxLines: null,
            overflow: TextOverflow.visible,
            style: widget.overlay.text.isEmpty
                ? _textStyle.copyWith(
                    color: widget.overlay.color.withValues(alpha: 0.45),
                  )
                : _textStyle,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Center(child: textWidget),
    );
  }

  Widget _buildHandleKnob() {
    return SizedBox(
      width: OverlayGeometry.knobSize,
      height: OverlayGeometry.knobSize,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: AppTheme.accent, width: 2),
          boxShadow: const [
            BoxShadow(blurRadius: 3, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showChrome = widget.selected || widget.editing;

    final topLeft = OverlayGeometry.chromeTopLeft(
      previewW: widget.previewWidth,
      previewH: widget.previewHeight,
      overlay: widget.overlay,
      liveW: widget.liveWidth,
      liveH: widget.liveHeight,
      liveOffset: widget.liveOffset,
    );

    final boxW = _boxWidth;
    final boxH = _boxHeight;

    Widget chrome = Padding(
      padding: const EdgeInsets.all(OverlayGeometry.handlePad),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: showChrome
                ? BoxDecoration(
                    border: Border.all(color: AppTheme.accent, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  )
                : const BoxDecoration(),
            child: SizedBox(
              width: boxW,
              height: boxH,
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: [
                  Expanded(child: _buildBody()),
                  if (showChrome)
                    IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: SizedBox(
                          width: 44,
                          height: 28,
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(2),
                                ),
                              ),
                              child: const SizedBox(width: 24, height: 5),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (showChrome) ...[
            Positioned(
              left: -OverlayGeometry.knobOutset,
              top: -OverlayGeometry.knobOutset,
              child: _buildHandleKnob(),
            ),
            Positioned(
              right: -OverlayGeometry.knobOutset,
              top: -OverlayGeometry.knobOutset,
              child: _buildHandleKnob(),
            ),
            Positioned(
              left: -OverlayGeometry.knobOutset,
              bottom: -OverlayGeometry.knobOutset,
              child: _buildHandleKnob(),
            ),
            Positioned(
              right: -OverlayGeometry.knobOutset,
              bottom: -OverlayGeometry.knobOutset,
              child: _buildHandleKnob(),
            ),
          ],
        ],
      ),
    );

    if (widget.editing) {
      chrome = TapRegion(
        onTapOutside: (_) {
          _log('tapOutsideDismiss', {'source': 'tap_region'});
          widget.onEditingComplete?.call('tap_region');
        },
        child: chrome,
      );
    }

    // Only the text field takes pointers; selection, move and resize are hit
    // tested in preview coordinates by [VideoPreviewWithOverlaysState].
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      child: IgnorePointer(
        ignoring: !widget.editing,
        child: chrome,
      ),
    );
  }
}

class _VideoCanvasBackground extends StatelessWidget {
  const _VideoCanvasBackground({
    required this.videoAspectRatio,
    required this.videoChild,
  });

  final double videoAspectRatio;
  final Widget videoChild;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: videoAspectRatio,
            child: videoChild,
          ),
        ),
      ),
    );
  }
}
