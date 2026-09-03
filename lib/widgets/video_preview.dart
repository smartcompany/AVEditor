import 'dart:math' as math;

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/widgets/text_template_pack_browser.dart';
import 'package:flutter/material.dart';

export 'overlay_geometry.dart' show OverlayGeometry, OverlayBox;

/// Limits in frame pixels — see [kOverlayFrameWidth].
const double minOverlayFontSize = 24;
const double maxOverlayFontSize = 240;
const double minOverlayBoxWidth = 120;
const double minOverlayBoxHeight = 96;
const double maxOverlayBoxWidth = kOverlayFrameWidth * 1.3;
const double maxOverlayBoxHeight = kOverlayFrameHeight * 1.3;

/// Normalized offset from center — allows placing boxes into letterbox / past edges.
const double maxOverlayOffset = 3.5;

/// An overlay's geometry after a drag, in frame pixels.
@immutable
class OverlayTransform {
  const OverlayTransform({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.offset,
    required this.rotation,
  });

  final double width;
  final double height;
  final double fontSize;
  final Offset offset;
  final double rotation;
}

/// Reports a drag result: box and font always scale by the same factor.
typedef OverlayBoxChanged =
    void Function(TextOverlay overlay, OverlayTransform transform);

/// 9:16 preview with time-bound, draggable text overlays.
class VideoPreviewWithOverlays extends StatefulWidget {
  const VideoPreviewWithOverlays({
    super.key,
    required this.videoChild,
    required this.videoAspectRatio,
    required this.overlays,
    required this.position,
    this.segments = const [],
    this.clipRotation = 0,
    this.selectedOverlayId,
    this.editingOverlayId,
    this.textHint,
    this.onOverlayOffsetChanged,
    this.onOverlayBoxChanged,
    this.onOverlaySelected,
    this.onOverlayTextChanged,
    this.onEditingComplete,
    this.onRequestEdit,
    this.onBackgroundTap,
    this.onOverlayDeleted,
    this.onOverlayDuplicated,
    this.onOverlayEdit,
  });

  final Widget videoChild;
  final double videoAspectRatio;
  final List<TextOverlay> overlays;
  final Duration position;
  final List<ClipSegment> segments;

  /// Clockwise tilt of the video frame, in radians.
  final double clipRotation;
  final String? selectedOverlayId;
  final String? editingOverlayId;
  final String? textHint;
  final void Function(TextOverlay overlay, Offset offset)?
  onOverlayOffsetChanged;
  final OverlayBoxChanged? onOverlayBoxChanged;
  final ValueChanged<TextOverlay>? onOverlaySelected;
  final void Function(TextOverlay overlay, String text)? onOverlayTextChanged;
  final void Function(String source)? onEditingComplete;
  final ValueChanged<TextOverlay>? onRequestEdit;

  /// Tap that landed on the canvas but on no overlay.
  final VoidCallback? onBackgroundTap;

  /// Top-left corner handle.
  final ValueChanged<TextOverlay>? onOverlayDeleted;

  /// Bottom-left corner handle.
  final ValueChanged<TextOverlay>? onOverlayDuplicated;

  /// Top-right corner handle — opens the style / text editor sheet.
  final ValueChanged<TextOverlay>? onOverlayEdit;

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
  /// Overlay under the active pointer — may differ from [widget.selectedOverlayId]
  /// until the parent rebuilds after a fresh select-on-down.
  TextOverlay? _gestureOverlay;
  /// True when this press selected a new overlay; release must not open edit.
  bool _suppressEditOnRelease = false;
  Offset? _lastLocal;
  bool _pointerMoved = false;
  double _pointerTravel = 0;
  int _moveLogCounter = 0;
  OverlayBox? _liveBox;
  OverlayBox? _resizeStartBox;
  Offset _resizeAccumulated = Offset.zero;

  /// Pointer vector from the box centre when a resize+rotate drag began.
  Offset? _rotateStartVector;

  /// Every pointer currently down, in canvas coordinates. A second finger
  /// cancels any in-progress overlay gesture without affecting the video.
  final Map<int, Offset> _downPointers = {};
  double _previewW = 0;
  double _previewH = 0;

  double get _clipRotation => widget.clipRotation;

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
      .where((overlay) {
        if (widget.segments.isEmpty) {
          return overlay.isVisibleAt(widget.position);
        }
        return isOverlayVisibleAt(overlay, widget.segments, widget.position);
      })
      .toList(growable: false);

  /// Preview-canvas pixels per frame pixel.
  double get _frameScale => _previewW / kOverlayFrameWidth;

  /// [overlay]'s box in canvas pixels, including any in-progress drag.
  OverlayBox _boxOf(TextOverlay overlay) {
    final liveId = _gestureOverlay?.id ?? widget.selectedOverlayId;
    if (overlay.id == liveId) {
      final live = _liveBox;
      if (live != null) return live;
    }
    final scale = _frameScale;
    return OverlayBox(
      width: overlay.boxWidth * scale,
      height: overlay.boxHeight * scale,
      fontSize: overlay.fontSize * scale,
      offset: overlay.offset,
      rotation: overlay.rotation,
    );
  }

  void _clearLiveGeometry() {
    _liveBox = null;
  }

  void _clearDragState() {
    _activeDrag = null;
    _activePointer = null;
    _tapTarget = null;
    _gestureOverlay = null;
    _suppressEditOnRelease = false;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
    _moveLogCounter = 0;
    _resizeStartBox = null;
    _resizeAccumulated = Offset.zero;
    _rotateStartVector = null;
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

  void _moveBy(TextOverlay overlay, Offset delta) {
    final box = _boxOf(overlay);
    final next = Offset(
      (box.offset.dx + delta.dx / (_previewW / 2)).clamp(
        -maxOverlayOffset,
        maxOverlayOffset,
      ),
      (box.offset.dy + delta.dy / (_previewH / 2)).clamp(
        -maxOverlayOffset,
        maxOverlayOffset,
      ),
    );
    setState(() => _liveBox = box.copyWith(offset: next));
  }

  /// Corner drags scale the box and the font by one factor, so the text keeps
  /// filling the box and never distorts.
  void _resizeBy(
    TextOverlay overlay, {
    required Offset delta,
    required bool fromLeft,
    required bool fromTop,
  }) {
    final start = _resizeStartBox ?? _boxOf(overlay);
    _resizeStartBox ??= start;
    _resizeAccumulated += delta;

    final outward = Offset(
      fromLeft ? -_resizeAccumulated.dx : _resizeAccumulated.dx,
      fromTop ? -_resizeAccumulated.dy : _resizeAccumulated.dy,
    );
    // Project the drag onto the box diagonal so both axes contribute.
    final diagonal = Offset(start.width, start.height);
    final along =
        (outward.dx * diagonal.dx + outward.dy * diagonal.dy) /
        diagonal.distanceSquared;

    final scale = (1 + along).clamp(
      _minResizeScale(start),
      _maxResizeScale(start),
    );
    final next = start.scaled(scale);

    // Keep the opposite corner pinned. The box may be rotated, so the shift is
    // computed along the box's own axes and then rotated into canvas space.
    final signX = fromLeft ? -1.0 : 1.0;
    final signY = fromTop ? -1.0 : 1.0;
    final grow = Offset(
      signX * (next.width - start.width) / 2,
      signY * (next.height - start.height) / 2,
    );
    final rotated = _rotateVector(grow, start.rotation);
    final nextOffset = Offset(
      (start.offset.dx + rotated.dx / (_previewW / 2)).clamp(
        -maxOverlayOffset,
        maxOverlayOffset,
      ),
      (start.offset.dy + rotated.dy / (_previewH / 2)).clamp(
        -maxOverlayOffset,
        maxOverlayOffset,
      ),
    );

    setState(() => _liveBox = next.copyWith(offset: nextOffset));
  }

  /// Bottom-right corner: distance from the centre scales, angle rotates.
  ///
  /// The centre stays pinned so the box turns under the finger instead of
  /// swinging away from it.
  void _resizeRotateTo(TextOverlay overlay, Offset local) {
    final start = _resizeStartBox ?? _boxOf(overlay);
    _resizeStartBox ??= start;

    final centre = OverlayGeometry.boxCenter(
      previewW: _previewW,
      previewH: _previewH,
      box: start,
    );
    final from = _rotateStartVector;
    final to = local - centre;
    if (from == null || from.distance < 1 || to.distance < 1) return;

    final scale = (to.distance / from.distance).clamp(
      _minResizeScale(start),
      _maxResizeScale(start),
    );
    final rotation = start.rotation + (to.direction - from.direction);

    setState(
      () => _liveBox = start.scaled(scale).copyWith(rotation: rotation),
    );
  }

  static Offset _rotateVector(Offset v, double radians) {
    if (radians == 0) return v;
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    return Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos);
  }

  double _minResizeScale(OverlayBox start) {
    final scale = _frameScale;
    return [
      minOverlayBoxWidth * scale / start.width,
      minOverlayBoxHeight * scale / start.height,
      minOverlayFontSize * scale / start.fontSize,
    ].reduce((a, b) => a > b ? a : b);
  }

  double _maxResizeScale(OverlayBox start) {
    final scale = _frameScale;
    return [
      maxOverlayBoxWidth * scale / start.width,
      maxOverlayBoxHeight * scale / start.height,
      maxOverlayFontSize * scale / start.fontSize,
    ].reduce((a, b) => a < b ? a : b);
  }

  void _beginDrag(TextOverlay overlay, OverlayDrag drag, Offset local) {
    final box = _boxOf(overlay);
    OverlayEventLog.log('PreviewDrag', 'dragBegin', {
      'id': overlay.id.substring(0, 8),
      'drag': drag.label,
      'boxW': box.width,
      'boxH': box.height,
    });
    _activeDrag = drag;
    if (drag.isResize) {
      _resizeStartBox = box;
      _resizeAccumulated = Offset.zero;
      // Anchored on the press, not the first move, so a single large move
      // still rotates by the angle the finger actually swept.
      _rotateStartVector = local -
          OverlayGeometry.boxCenter(
            previewW: _previewW,
            previewH: _previewH,
            box: box,
          );
    }
  }

  void _commitDrag(TextOverlay overlay, bool moved) {
    final drag = _activeDrag;
    if (!moved || drag == null) return;

    final box = _boxOf(overlay);
    final scale = _frameScale;
    OverlayEventLog.log('PreviewDrag', 'commitGeometry', {
      'id': overlay.id.substring(0, 8),
      'drag': drag.label,
      'frameW': box.width / scale,
      'frameH': box.height / scale,
      'font': box.fontSize / scale,
      'offset': box.offset,
      'rotation': box.rotation,
    });
    if (drag.isResize) {
      widget.onOverlayBoxChanged?.call(
        overlay,
        OverlayTransform(
          width: box.width / scale,
          height: box.height / scale,
          fontSize: box.fontSize / scale,
          offset: box.offset,
          rotation: box.rotation,
        ),
      );
    } else {
      widget.onOverlayOffsetChanged?.call(overlay, box.offset);
    }
    _clearLiveGeometry();
  }

  TextOverlay? _topmostBodyAt(Offset local) {
    for (final overlay in _visibleOverlays.reversed) {
      final hit = OverlayGeometry.bodyContains(
        local,
        previewW: _previewW,
        previewH: _previewH,
        box: _boxOf(overlay),
      );
      if (hit) return overlay;
    }
    return null;
  }

  /// A second finger means the user is pinching — abandon any overlay drag
  /// without committing and leave the video frame untouched.
  void _cancelForMultiTouch() {
    _clearDragState();
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

    _downPointers[event.pointer] = local;
    if (_downPointers.length >= 2) {
      _cancelForMultiTouch();
      return;
    }

    final editing = _editingOverlay;
    if (editing != null) {
      final insideChrome = OverlayGeometry.chromeContains(
        local,
        previewW: _previewW,
        previewH: _previewH,
        box: _boxOf(editing),
      );
      if (insideChrome) return;
      OverlayEventLog.log('PreviewCanvas', 'dismissEditing', {'local': local});
      widget.onEditingComplete?.call('preview_outside');
      return;
    }

    if (_activePointer != null) return;

    _suppressEditOnRelease = false;
    _gestureOverlay = null;

    final selected = _selectedOverlay;
    if (selected != null) {
      final drag = OverlayGeometry.hitTestPreviewPoint(
        local,
        previewW: _previewW,
        previewH: _previewH,
        box: _boxOf(selected),
        editing: false,
      );
      if (drag != null) {
        OverlayEventLog.log('PreviewCanvas', 'dragStart', {
          'local': local,
          'drag': drag.label,
          'id': selected.id,
        });
        _activePointer = event.pointer;
        _lastLocal = local;
        _pointerMoved = false;
        _pointerTravel = 0;
        _moveLogCounter = 0;
        _gestureOverlay = selected;
        // A body press that never travels is a tap → open the inline editor.
        // Corner presses are resolved from the drag kind on release instead.
        _tapTarget = drag.kind == OverlayDragKind.move ? selected : null;
        _beginDrag(selected, drag, local);
        return;
      }
    }

    // Unselected (or another) text: grab immediately so the press never
    // falls through to video play/pause, and drag works without edit mode.
    final tapped = _topmostBodyAt(local);
    OverlayEventLog.log('PreviewCanvas', 'bodyProbe', {
      'local': local,
      'hit': tapped?.id,
    });
    if (tapped != null) {
      if (tapped.id != widget.selectedOverlayId) {
        _suppressEditOnRelease = true;
        widget.onOverlaySelected?.call(tapped);
      }
      _activePointer = event.pointer;
      _lastLocal = local;
      _pointerMoved = false;
      _pointerTravel = 0;
      _moveLogCounter = 0;
      _gestureOverlay = tapped;
      _tapTarget = tapped;
      OverlayEventLog.log('PreviewCanvas', 'dragStart', {
        'local': local,
        'drag': 'move',
        'id': tapped.id,
        'freshSelect': _suppressEditOnRelease,
      });
      _beginDrag(tapped, OverlayDrag.move, local);
      return;
    }

    // Empty canvas: releasing without travel toggles playback.
    _activePointer = event.pointer;
    _lastLocal = local;
    _pointerMoved = false;
    _pointerTravel = 0;
    _tapTarget = null;
  }

  void handlePointerMove(PointerMoveEvent event) {
    if (_downPointers.containsKey(event.pointer)) {
      final local = _toPreviewLocal(event);
      if (local != null) _downPointers[event.pointer] = local;
    }
    if (_downPointers.length >= 2) return;

    if (event.pointer != _activePointer) return;
    _pointerTravel += event.delta.distance;
    if (_pointerTravel > _tapSlop) _pointerMoved = true;
    final overlay = _gestureOverlay ?? _selectedOverlay;
    if (overlay == null || _activeDrag == null) return;
    _onPreviewPointerMoveAt(event, overlay);
  }

  void handlePointerUp(int pointer) {
    _downPointers.remove(pointer);
    if (_downPointers.isNotEmpty) return;

    if (pointer != _activePointer) return;
    final target = _tapTarget;
    final moved = _pointerMoved;
    final drag = _activeDrag;
    final dragged = _gestureOverlay ?? _selectedOverlay;
    final suppressEdit = _suppressEditOnRelease;

    if (drag != null && dragged != null) {
      _onPreviewPointerEnd(dragged, pointer);
    }

    _activePointer = null;
    _tapTarget = null;
    _gestureOverlay = null;
    _suppressEditOnRelease = false;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;

    if (moved) return;

    if (drag != null && drag.isTapAction && dragged != null) {
      OverlayEventLog.log('PreviewCanvas', 'cornerAction', {
        'id': dragged.id,
        'drag': drag.label,
      });
      switch (drag.kind) {
        case OverlayDragKind.delete:
          widget.onOverlayDeleted?.call(dragged);
        case OverlayDragKind.duplicate:
          widget.onOverlayDuplicated?.call(dragged);
        case OverlayDragKind.edit:
          widget.onOverlayEdit?.call(dragged);
        case OverlayDragKind.move:
        case OverlayDragKind.resize:
        case OverlayDragKind.resizeRotate:
          break;
      }
      return;
    }

    if (target == null) {
      // Corner presses also clear the tap target, so check no drag ran.
      if (drag != null) return;
      OverlayEventLog.log('PreviewCanvas', 'tapBackground', {});
      widget.onBackgroundTap?.call();
      return;
    }

    // Text hit: never toggle playback. Fresh select stays selected; a second
    // tap on an already-selected overlay opens inline edit.
    if (!suppressEdit && target.id == widget.selectedOverlayId) {
      OverlayEventLog.log('PreviewCanvas', 'tapRequestEdit', {'id': target.id});
      widget.onRequestEdit?.call(target);
    } else {
      OverlayEventLog.log('PreviewCanvas', 'tapSelect', {'id': target.id});
      if (target.id != widget.selectedOverlayId) {
        widget.onOverlaySelected?.call(target);
      }
    }
  }

  void handlePointerCancel(int pointer) {
    _downPointers.remove(pointer);
    if (_downPointers.isNotEmpty) return;

    if (pointer != _activePointer) return;
    final overlay = _gestureOverlay ?? _selectedOverlay;
    if (overlay != null && _activeDrag != null) {
      _onPreviewPointerEnd(overlay, pointer);
    }
    _activePointer = null;
    _tapTarget = null;
    _gestureOverlay = null;
    _suppressEditOnRelease = false;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
  }

  Offset? _toPreviewLocal(PointerEvent event) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(event.position);
  }

  void _onPreviewPointerMoveAt(PointerMoveEvent event, TextOverlay overlay) {
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
    switch (drag.kind) {
      case OverlayDragKind.move:
        _moveBy(overlay, delta);
      case OverlayDragKind.resizeRotate:
        _resizeRotateTo(overlay, local);
      case OverlayDragKind.resize:
        _resizeBy(
          overlay,
          delta: delta,
          fromLeft: drag.fromLeft!,
          fromTop: drag.fromTop!,
        );
      case OverlayDragKind.delete:
      case OverlayDragKind.duplicate:
      case OverlayDragKind.edit:
        // Corner buttons: travel is ignored, the action fires on release.
        break;
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
    if (!moved && _liveBox != null) {
      setState(_clearLiveGeometry);
    }
    _activeDrag = null;
    _activePointer = null;
    _lastLocal = null;
    _pointerMoved = false;
    _pointerTravel = 0;
    _moveLogCounter = 0;
    _resizeStartBox = null;
    _resizeAccumulated = Offset.zero;
    _rotateStartVector = null;
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

            return OverflowHitStack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: _VideoCanvasBackground(
                    videoAspectRatio: widget.videoAspectRatio,
                    videoChild: widget.videoChild,
                    rotation: _clipRotation,
                  ),
                ),
                ...visible.map(
                  (overlay) => _DraggableOverlayLabel(
                    key: ValueKey(overlay.id),
                    overlay: overlay,
                    box: _boxOf(overlay),
                    previewWidth: _previewW,
                    previewHeight: _previewH,
                    selected: overlay.id == widget.selectedOverlayId,
                    editing: overlay.id == widget.editingOverlayId,
                    textHint: widget.textHint,
                    onTextChanged: (text) =>
                        widget.onOverlayTextChanged?.call(overlay, text),
                    onEditingComplete: widget.onEditingComplete,
                  ),
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
    required this.box,
    required this.previewWidth,
    required this.previewHeight,
    required this.selected,
    required this.editing,
    required this.onTextChanged,
    this.onEditingComplete,
    this.textHint,
  });

  final TextOverlay overlay;

  /// Size, font and offset already resolved into canvas pixels.
  final OverlayBox box;
  final double previewWidth;
  final double previewHeight;
  final bool selected;
  final bool editing;
  final String? textHint;
  final ValueChanged<String> onTextChanged;
  final void Function(String source)? onEditingComplete;

  @override
  State<_DraggableOverlayLabel> createState() => _DraggableOverlayLabelState();
}

class _DraggableOverlayLabelState extends State<_DraggableOverlayLabel> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  static const _logTag = 'OverlayLabel';

  String get _overlayIdShort => widget.overlay.id.length <= 8
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

  TextStyle get _fillStyle {
    final template = resolveOverlayTemplate(widget.overlay);
    return TextStyle(
      fontFamily: overlayFontFamily,
      color: template.resolveFill(widget.overlay.color),
      fontSize: widget.box.fontSize,
      fontWeight: FontWeight.w700,
      height: 1.15,
    );
  }

  Widget _buildBody() {
    final template = resolveOverlayTemplate(widget.overlay);
    final fill = template.resolveFill(widget.overlay.color);
    final hintColor = fill.withValues(alpha: 0.45);

    if (widget.editing) {
      final field = MediaQuery.withNoTextScaling(
        child: Center(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            maxLines: null,
            textAlign: TextAlign.center,
            style: _fillStyle,
            cursorColor: AppTheme.accent,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: widget.textHint,
              hintStyle: _fillStyle.copyWith(color: hintColor),
            ),
            onChanged: widget.onTextChanged,
            onEditingComplete: () =>
                widget.onEditingComplete?.call('textfield_done'),
            onSubmitted: (_) =>
                widget.onEditingComplete?.call('textfield_submit'),
          ),
        ),
      );
      final packId = widget.overlay.packItemId;
      if (packId == null) return field;
      return Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          IgnorePointer(
            child: PackLottieDecoration(
              packItemId: packId,
              width: widget.box.width * 1.15,
              height: widget.box.height * 1.4,
            ),
          ),
          field,
        ],
      );
    }

    final isHint = widget.overlay.text.isEmpty;
    final text = OverlayTextDisplay(
      text: isHint ? (widget.textHint ?? '') : widget.overlay.text,
      color: widget.overlay.color,
      fontSize: widget.box.fontSize,
      maxWidth: widget.box.width,
      template: template,
      hintColor: isHint ? hintColor : null,
    );

    final packId = widget.overlay.packItemId;
    final body = packId == null
        ? text
        : Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              PackLottieDecoration(
                packItemId: packId,
                width: widget.box.width * 1.15,
                height: widget.box.height * 1.15,
              ),
              text,
            ],
          );

    return MediaQuery.withNoTextScaling(child: Center(child: body));
  }

  Widget _buildMoveGrip() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(Radius.circular(3)),
        boxShadow: [BoxShadow(blurRadius: 3, color: Colors.black54)],
      ),
      child: const SizedBox(width: 28, height: 6),
    );
  }

  static const _iconKnobSize = 24.0;

  Widget _buildIconKnob(IconData icon) {
    return Container(
      width: _iconKnobSize,
      height: _iconKnobSize,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.accent, width: 1.5),
        boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black54)],
      ),
      child: Center(
        child: Icon(icon, size: 14, color: AppTheme.accent),
      ),
    );
  }

  /// Distance from the box edge to a corner handle's centre.
  static const _anchorOutset =
      OverlayGeometry.knobOutset - OverlayGeometry.knobSize / 2;

  /// Centres [child] on the corner anchor that [OverlayGeometry] hit tests,
  /// whatever its size.
  Widget _corner({
    required Widget child,
    required double size,
    required bool left,
    required bool top,
  }) {
    final inset = -_anchorOutset - size / 2;
    return Positioned(
      left: left ? inset : null,
      right: left ? null : inset,
      top: top ? inset : null,
      bottom: top ? null : inset,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showChrome = widget.selected || widget.editing;

    final topLeft = OverlayGeometry.chromeTopLeft(
      previewW: widget.previewWidth,
      previewH: widget.previewHeight,
      box: widget.box,
    );

    final boxW = widget.box.width;
    final boxH = widget.box.height;

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
            child: SizedBox(width: boxW, height: boxH, child: _buildBody()),
          ),
          if (showChrome) ...[
            // Grip lives in the padding ring so it never steals text space.
            Positioned(
              bottom: -OverlayGeometry.gripOutset - 3,
              child: IgnorePointer(child: _buildMoveGrip()),
            ),
            _corner(
              left: true,
              top: true,
              size: _iconKnobSize,
              child: _buildIconKnob(Icons.delete_outline),
            ),
            _corner(
              left: false,
              top: true,
              size: _iconKnobSize,
              child: _buildIconKnob(Icons.edit_outlined),
            ),
            _corner(
              left: true,
              top: false,
              size: _iconKnobSize,
              child: _buildIconKnob(Icons.content_copy),
            ),
            _corner(
              left: false,
              top: false,
              size: _iconKnobSize,
              child: _buildIconKnob(Icons.rotate_right),
            ),
          ],
        ],
      ),
    );

    if (widget.box.rotation != 0) {
      chrome = Transform.rotate(angle: widget.box.rotation, child: chrome);
    }

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
      child: IgnorePointer(ignoring: !widget.editing, child: chrome),
    );
  }
}

class _VideoCanvasBackground extends StatelessWidget {
  const _VideoCanvasBackground({
    required this.videoAspectRatio,
    required this.videoChild,
    required this.rotation,
  });

  final double videoAspectRatio;
  final Widget videoChild;
  final double rotation;

  @override
  Widget build(BuildContext context) {
    // Cover, not contain: the export scales up and centre-crops to fill the
    // preset frame, so showing the video letterboxed here would promise bars
    // that the exported file does not have.
    Widget video = FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: videoAspectRatio * 1000,
        height: 1000,
        child: videoChild,
      ),
    );

    if (rotation != 0) {
      video = Transform.rotate(angle: rotation, child: video);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(color: Colors.black, child: video),
    );
  }
}
