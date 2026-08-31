import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:flutter/material.dart';

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
class VideoPreviewWithOverlays extends StatelessWidget {
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
  /// When set, that overlay shows an inline [TextField] with keyboard focus.
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
  Widget build(BuildContext context) {
    final visible = overlays.where((o) => o.isVisibleAt(position)).toList();

    return AspectRatio(
      aspectRatio: 9 / 16,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final previewW = constraints.maxWidth;
          final previewH = constraints.maxHeight;
          // Full preview canvas — includes letterbox, not just the video rect.
          final maxBoxW = previewW + 96;
          final maxBoxH = previewH + 96;

          return OverflowHitStack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              ClipRRect(
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
              ),
              if (editingOverlayId != null)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      OverlayEventLog.log(
                        'Preview',
                        'tapOutsideDismiss',
                        {'source': 'letterbox'},
                      );
                      onEditingComplete?.call('letterbox');
                    },
                  ),
                ),
              ...visible.map(
                (overlay) => _DraggableOverlayLabel(
                  key: ValueKey(overlay.id),
                  overlay: overlay,
                  previewWidth: previewW,
                  previewHeight: previewH,
                  maxBoxWidth: maxBoxW,
                  maxBoxHeight: maxBoxH,
                  selected: overlay.id == selectedOverlayId,
                  editing: overlay.id == editingOverlayId,
                  textHint: textHint,
                  onSelected: () => onOverlaySelected?.call(overlay),
                  onRequestEdit: () => onRequestEdit?.call(overlay),
                  onOffsetChanged: (offset) =>
                      onOverlayOffsetChanged?.call(overlay, offset),
                  onBoxChanged: (width, height, offset) =>
                      onOverlayBoxChanged?.call(overlay, width, height, offset),
                  onTextChanged: (text) =>
                      onOverlayTextChanged?.call(overlay, text),
                  onEditingComplete: onEditingComplete,
                ),
              ),
            ],
          );
        },
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
    required this.onSelected,
    required this.onRequestEdit,
    required this.onOffsetChanged,
    required this.onBoxChanged,
    required this.onTextChanged,
    this.onEditingComplete,
    this.textHint,
  });

  final TextOverlay overlay;
  final double previewWidth;
  final double previewHeight;
  final double maxBoxWidth;
  final double maxBoxHeight;
  final bool selected;
  final bool editing;
  final String? textHint;
  final VoidCallback onSelected;
  final VoidCallback onRequestEdit;
  final ValueChanged<Offset> onOffsetChanged;
  final void Function(double width, double height, Offset offset) onBoxChanged;
  final ValueChanged<String> onTextChanged;
  final void Function(String source)? onEditingComplete;

  @override
  State<_DraggableOverlayLabel> createState() => _DraggableOverlayLabelState();
}

class _DraggableOverlayLabelState extends State<_DraggableOverlayLabel> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  double? _resizeStartWidth;
  double? _resizeStartHeight;
  Offset? _resizeStartOffset;
  Offset _resizeAccumulated = Offset.zero;
  _OverlayDrag? _activeDrag;
  bool _wasEditingBeforeDrag = false;
  int? _activePointer;
  bool _pointerMoved = false;
  int _moveLogCounter = 0;
  double? _liveWidth;
  double? _liveHeight;
  Offset? _liveOffset;

  double get _boxWidth => _liveWidth ?? widget.overlay.boxWidth;
  double get _boxHeight => _liveHeight ?? widget.overlay.boxHeight;
  Offset get _boxOffset => _liveOffset ?? widget.overlay.offset;

  void _clearLiveGeometry() {
    _liveWidth = null;
    _liveHeight = null;
    _liveOffset = null;
  }

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
  static const _handleHit = 56.0;
  static const _knobSize = 14.0;
  static const _knobOutset = 22.0;
  /// Must fit corner knob + hit slop inside the padded listener bounds.
  static const _handlePad =
      _knobOutset + _knobSize / 2 + _handleHit / 2 + 4;

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
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _DraggableOverlayLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing && !widget.editing) {
      _log('editingEnded', {
        'clearedDrag': _activeDrag != null || _activePointer != null,
      });
      _activePointer = null;
      _activeDrag = null;
      _wasEditingBeforeDrag = false;
      _pointerMoved = false;
      _moveLogCounter = 0;
      _suppressBodyTapUntil = null;
      _resizeStartWidth = null;
      _resizeStartHeight = null;
      _resizeStartOffset = null;
      _resizeAccumulated = Offset.zero;
      _clearLiveGeometry();
    }
    if (!oldWidget.editing && widget.editing) {
      _log('editingStarted');
    }
    if (_activeDrag == null &&
        (oldWidget.overlay.boxWidth != widget.overlay.boxWidth ||
            oldWidget.overlay.boxHeight != widget.overlay.boxHeight ||
            oldWidget.overlay.offset != widget.overlay.offset)) {
      _clearLiveGeometry();
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

  double _pointerScale(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 1;
    return box.getTransformTo(null).getMaxScaleOnAxis().clamp(0.001, 100);
  }

  Offset _scaledDelta(BuildContext context, Offset delta) {
    return delta / _pointerScale(context);
  }

  TextStyle get _textStyle => TextStyle(
        color: widget.overlay.color,
        fontSize: widget.overlay.fontSize,
        fontWeight: FontWeight.w700,
        shadows: const [
          Shadow(blurRadius: 8, color: Colors.black54),
        ],
      );

  void _moveBy(BuildContext context, Offset delta) {
    final scaled = _scaledDelta(context, delta);
    const sensitivity = 180.0;
    final current = _boxOffset;
    final nextDx =
        (current.dx + scaled.dx / sensitivity).clamp(-maxOverlayOffset, maxOverlayOffset);
    final nextDy =
        (current.dy + scaled.dy / sensitivity).clamp(-maxOverlayOffset, maxOverlayOffset);
    setState(() => _liveOffset = Offset(nextDx, nextDy));
  }

  /// Corner drag: opposite corner stays fixed; box can grow into letterbox.
  void _resizeBy(
    BuildContext context,
    Offset delta, {
    required bool fromLeft,
    required bool fromTop,
  }) {
    final scaled = _scaledDelta(context, delta);
    _resizeAccumulated += scaled;
    final startW = _resizeStartWidth ?? widget.overlay.boxWidth;
    final startH = _resizeStartHeight ?? widget.overlay.boxHeight;
    final startOffset = _resizeStartOffset ?? widget.overlay.offset;
    _resizeStartWidth ??= startW;
    _resizeStartHeight ??= startH;
    _resizeStartOffset ??= startOffset;

    final outwardW = fromLeft ? -_resizeAccumulated.dx : _resizeAccumulated.dx;
    final outwardH = fromTop ? -_resizeAccumulated.dy : _resizeAccumulated.dy;

    final nextW =
        (startW + outwardW).clamp(minOverlayBoxWidth, widget.maxBoxWidth);
    final nextH =
        (startH + outwardH).clamp(minOverlayBoxHeight, widget.maxBoxHeight);

    // Shift center so the corner opposite the handle stays anchored.
    final appliedW = nextW - startW;
    final appliedH = nextH - startH;
    final signX = fromLeft ? -1.0 : 1.0;
    final signY = fromTop ? -1.0 : 1.0;
    final nextOffset = Offset(
      (startOffset.dx + signX * appliedW / widget.previewWidth)
          .clamp(-maxOverlayOffset, maxOverlayOffset),
      (startOffset.dy + signY * appliedH / widget.previewHeight)
          .clamp(-maxOverlayOffset, maxOverlayOffset),
    );

    if ((nextW - _boxWidth).abs() >= 0.5 ||
        (nextH - _boxHeight).abs() >= 0.5 ||
        nextOffset != _boxOffset) {
      setState(() {
        _liveWidth = nextW;
        _liveHeight = nextH;
        _liveOffset = nextOffset;
      });
    }
  }

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

  _OverlayDrag? _hitTestDrag(Offset local, double boxW, double boxH) {
    final pad = _handlePad;
    final knobRadius = _knobSize / 2;
    final hit = _handleHit / 2;

    // Match visual knob centers (Positioned ±22 from box edge, 14px knob).
    final corners = <(Offset, _OverlayDrag)>[
      (
        Offset(pad - _knobOutset + knobRadius, pad - _knobOutset + knobRadius),
        _OverlayDrag.resize(fromLeft: true, fromTop: true),
      ),
      (
        Offset(
          pad + boxW + _knobOutset - knobRadius,
          pad - _knobOutset + knobRadius,
        ),
        _OverlayDrag.resize(fromLeft: false, fromTop: true),
      ),
      (
        Offset(
          pad - _knobOutset + knobRadius,
          pad + boxH + _knobOutset - knobRadius,
        ),
        _OverlayDrag.resize(fromLeft: true, fromTop: false),
      ),
      (
        Offset(
          pad + boxW + _knobOutset - knobRadius,
          pad + boxH + _knobOutset - knobRadius,
        ),
        _OverlayDrag.resize(fromLeft: false, fromTop: false),
      ),
    ];

    for (final (anchor, drag) in corners) {
      if ((local - anchor).distance <= hit) return drag;
    }

    // Bottom-center move grip inside the box (white bar in the column footer).
    final moveCenter = Offset(pad + boxW / 2, pad + boxH - 14);
    if ((local - moveCenter).distance <= hit) {
      return _OverlayDrag.move;
    }

    // Body drag moves the overlay when not editing (most of the box interior).
    if (!widget.editing &&
        local.dx >= pad &&
        local.dx <= pad + boxW &&
        local.dy >= pad &&
        local.dy <= pad + boxH) {
      return _OverlayDrag.move;
    }

    return null;
  }

  String _dragLabel(_OverlayDrag drag) {
    if (drag.kind == _OverlayDragKind.move) return 'move';
    return 'resize_${drag.fromLeft == true ? 'L' : 'R'}${drag.fromTop == true ? 'T' : 'B'}';
  }

  void _beginDrag(_OverlayDrag drag) {
    _log('dragBegin', {
      'drag': _dragLabel(drag),
      'boxW': _boxWidth,
      'boxH': _boxHeight,
    });
    _activeDrag = drag;
    _wasEditingBeforeDrag = widget.editing;
    if (drag.isResize) {
      _resizeStartWidth = _boxWidth;
      _resizeStartHeight = _boxHeight;
      _resizeStartOffset = _boxOffset;
      _resizeAccumulated = Offset.zero;
    }
    if (widget.editing) {
      _focusNode.unfocus();
    }
  }

  void _commitDragToParent(bool moved) {
    final drag = _activeDrag;
    if (!moved || drag == null) return;

    final w = _boxWidth;
    final h = _boxHeight;
    final o = _boxOffset;
    _log('commitGeometry', {
      'drag': _dragLabel(drag),
      'boxW': w,
      'boxH': h,
      'offset': o,
    });
    if (drag.isResize) {
      widget.onBoxChanged(w, h, o);
    } else {
      widget.onOffsetChanged(o);
    }
    _clearLiveGeometry();
  }

  void _endDrag(bool moved) {
    final wasEditing = _wasEditingBeforeDrag;
    final drag = _activeDrag;
    _log('dragEnd', {
      'drag': drag == null ? 'none' : _dragLabel(drag),
      'moved': moved,
      'wasEditing': wasEditing,
    });
    _activeDrag = null;
    _wasEditingBeforeDrag = false;
    _resizeStartWidth = null;
    _resizeStartHeight = null;
    _resizeStartOffset = null;
    _resizeAccumulated = Offset.zero;
    if (wasEditing) {
      widget.onEditingComplete?.call('drag_end');
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.selected && !widget.editing) {
      _log('pointerDownIgnored', {
        'reason': 'not_selected',
        'local': event.localPosition,
        'pointer': event.pointer,
      });
      return;
    }
    if (_activePointer != null) {
      _log('pointerDownIgnored', {
        'reason': 'pointer_busy',
        'local': event.localPosition,
        'pointer': event.pointer,
        'activePointer': _activePointer,
      });
      return;
    }

    final drag = _hitTestDrag(
      event.localPosition,
      _boxWidth,
      _boxHeight,
    );
    if (drag == null) {
      _log('pointerDownMiss', {
        'local': event.localPosition,
        'pointer': event.pointer,
        'boxW': _boxWidth,
        'boxH': _boxHeight,
        'blockTextField': _blockTextFieldPointer,
      });
      return;
    }

    _log('pointerDownHit', {
      'local': event.localPosition,
      'pointer': event.pointer,
      'drag': _dragLabel(drag),
    });

    _activePointer = event.pointer;
    _pointerMoved = false;
    _moveLogCounter = 0;
    _beginDrag(drag);
  }

  void _onPointerMove(BuildContext context, PointerMoveEvent event) {
    if (event.pointer != _activePointer || _activeDrag == null) return;
    if (event.delta != Offset.zero) {
      _pointerMoved = true;
      _moveLogCounter++;
      if (_moveLogCounter == 1 || _moveLogCounter % 12 == 0) {
        _log('pointerMove', {
          'pointer': event.pointer,
          'delta': event.delta,
          'drag': _dragLabel(_activeDrag!),
          'count': _moveLogCounter,
          'scale': _pointerScale(context),
        });
      }
    }
    final drag = _activeDrag!;
    if (drag.kind == _OverlayDragKind.move) {
      _moveBy(context, event.delta);
    } else {
      _resizeBy(
        context,
        event.delta,
        fromLeft: drag.fromLeft!,
        fromTop: drag.fromTop!,
      );
    }
  }

  void _onPointerEnd(int pointer) {
    if (pointer != _activePointer) return;
    final moved = _pointerMoved;
    final moveCount = _moveLogCounter;
    _activePointer = null;
    _pointerMoved = false;
    _moveLogCounter = 0;
    _log('pointerUp', {'pointer': pointer, 'moved': moved, 'moveCount': moveCount});
    _commitDragToParent(moved);
    _endDrag(moved);
    if (moved) {
      _suppressBodyTapUntil =
          DateTime.now().add(const Duration(milliseconds: 120));
      _log('tapSuppressed', {'untilMs': 120});
    }
  }

  DateTime? _suppressBodyTapUntil;

  Widget _buildHandleKnob() {
    return SizedBox(
      width: _knobSize,
      height: _knobSize,
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

  bool get _blockTextFieldPointer =>
      _activeDrag != null || (widget.editing && !_focusNode.hasFocus);

  @override
  Widget build(BuildContext context) {
    final showChrome = widget.selected || widget.editing;

    final offset = _boxOffset;
    final centerX = widget.previewWidth / 2 + offset.dx * (widget.previewWidth / 2);
    final centerY = widget.previewHeight / 2 + offset.dy * (widget.previewHeight / 2);
    final left = centerX - _boxWidth / 2 - _handlePad;
    final top = centerY - _boxHeight / 2 - _handlePad;

    final boxW = _boxWidth;
    final boxH = _boxHeight;

    final box = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: (event) => _onPointerMove(context, event),
      onPointerUp: (event) => _onPointerEnd(event.pointer),
      onPointerCancel: (event) => _onPointerEnd(event.pointer),
      child: Padding(
        padding: const EdgeInsets.all(_handlePad),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_activeDrag != null) {
                  _log('bodyTapIgnored', {'reason': 'active_drag'});
                  return;
                }
                final suppressUntil = _suppressBodyTapUntil;
                if (suppressUntil != null &&
                    DateTime.now().isBefore(suppressUntil)) {
                  _log('bodyTapIgnored', {'reason': 'suppress_after_drag'});
                  return;
                }
                if (widget.editing) {
                  _log('bodyTapIgnored', {'reason': 'editing'});
                  return;
                }
                if (widget.selected) {
                  _log('bodyTap', {'action': 'request_edit'});
                  widget.onRequestEdit();
                } else {
                  _log('bodyTap', {'action': 'select'});
                  widget.onSelected();
                }
              },
              child: DecoratedBox(
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
                      Expanded(
                        child: IgnorePointer(
                          ignoring: _blockTextFieldPointer,
                          child: _buildBody(),
                        ),
                      ),
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
            ),
            if (showChrome) ...[
              Positioned(
                left: -_knobOutset,
                top: -_knobOutset,
                child: _buildHandleKnob(),
              ),
              Positioned(
                right: -_knobOutset,
                top: -_knobOutset,
                child: _buildHandleKnob(),
              ),
              Positioned(
                left: -_knobOutset,
                bottom: -_knobOutset,
                child: _buildHandleKnob(),
              ),
              Positioned(
                right: -_knobOutset,
                bottom: -_knobOutset,
                child: _buildHandleKnob(),
              ),
            ],
          ],
        ),
      ),
    );

    return Positioned(
      left: left,
      top: top,
      child: OverflowHitBox(
        child: widget.editing
            ? TapRegion(
                onTapOutside: (_) {
                  if (_activeDrag == null) {
                    _log('tapOutsideDismiss', {'source': 'tap_region'});
                    widget.onEditingComplete?.call('tap_region');
                  } else {
                    _log('tapOutsideIgnored', {'reason': 'active_drag'});
                  }
                },
                child: box,
              )
            : box,
      ),
    );
  }
}

enum _OverlayDragKind { move, resize }

class _OverlayDrag {
  const _OverlayDrag._(this.kind, {this.fromLeft, this.fromTop});

  final _OverlayDragKind kind;
  final bool? fromLeft;
  final bool? fromTop;

  static const move = _OverlayDrag._(_OverlayDragKind.move);

  static _OverlayDrag resize({required bool fromLeft, required bool fromTop}) {
    return _OverlayDrag._(
      _OverlayDragKind.resize,
      fromLeft: fromLeft,
      fromTop: fromTop,
    );
  }

  bool get isResize => kind == _OverlayDragKind.resize;
}
