import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:flutter/material.dart';

const _timelineHeight = 112.0;
const _videoTrackBottom = 0.52;
const _textTrackTop = 0.58;

enum TimelineDragTarget {
  scrubPlayhead,
  panTimeline,
  trimStart,
  trimEnd,
  overlayStart,
  overlayEnd,
  overlayMove,
}

/// Interactive timeline with pinch-zoom, playhead scrub, and background pan scrub.
class TimelineWidget extends StatefulWidget {
  const TimelineWidget({
    super.key,
    required this.duration,
    required this.trimStart,
    required this.trimEnd,
    required this.overlays,
    required this.playhead,
    required this.onPlayheadChanged,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
    required this.onOverlayChanged,
    this.onOverlaySelected,
    this.selectedOverlayId,
    this.isPlaying = false,
    this.onTogglePlay,
  });

  final Duration duration;
  final Duration trimStart;
  final Duration trimEnd;
  final List<TextOverlay> overlays;
  final Duration playhead;
  final ValueChanged<Duration> onPlayheadChanged;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  final ValueChanged<TextOverlay> onOverlayChanged;
  final ValueChanged<TextOverlay>? onOverlaySelected;
  final String? selectedOverlayId;
  final bool isPlaying;
  final VoidCallback? onTogglePlay;

  @override
  State<TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends State<TimelineWidget> {
  double _zoom = 1.0;
  double _scrollPx = 0;
  double _viewportWidth = 1;

  TimelineDragTarget _dragTarget = TimelineDragTarget.panTimeline;
  TextOverlay? _dragOverlay;
  Duration? _overlayAnchorStart;
  Duration? _overlayAnchorEnd;

  double _panPinnedPlayheadX = 0;
  /// While pan-scrubbing, paint the playhead at this fixed viewport X so it
  /// does not jitter between scroll updates and async seek/playhead props.
  bool _lockPlayheadViewportX = false;
  bool _didMove = false;
  Offset? _pointerDownLocal;
  Offset? _lastSingleLocal;

  /// Active pointer positions in local coords (Listener-based multi-touch).
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartZoom = 1.0;
  Duration _pinchFocalTime = Duration.zero;

  double get _contentWidth => _viewportWidth * _zoom;
  double get _contentInsetX =>
      timelineContentInsetX(_contentWidth, _viewportWidth);
  bool get _isPinching => _pointers.length >= 2;

  Duration _timeAtViewportX(double x, {bool snap = true}) {
    final time = viewportXToDuration(
      x: x,
      scrollPx: _scrollPx,
      total: widget.duration,
      contentWidth: _contentWidth,
      contentInsetX: _contentInsetX,
    );
    return snap ? snapDuration(time) : time;
  }

  double _viewportXFor(Duration time) {
    return durationToViewportX(
      time: time,
      scrollPx: _scrollPx,
      total: widget.duration,
      contentWidth: _contentWidth,
      contentInsetX: _contentInsetX,
    );
  }

  void _ensurePlayheadVisible() {
    final x = _viewportXFor(widget.playhead);
    const edge = 32.0;
    var nextScroll = _scrollPx;
    if (x < edge) {
      nextScroll = _scrollPx - (edge - x);
    } else if (x > _viewportWidth - edge) {
      nextScroll = _scrollPx + (x - (_viewportWidth - edge));
    }
    nextScroll = clampScrollPx(nextScroll, _contentWidth, _viewportWidth);
    if (nextScroll != _scrollPx) {
      setState(() => _scrollPx = nextScroll);
    }
  }

  void _setZoomAround({
    required double nextZoom,
    required Duration focalTime,
    required double focalViewportX,
  }) {
    final zoom = nextZoom.clamp(minTimelineZoom, maxTimelineZoom);
    final contentWidth = _viewportWidth * zoom;
    final inset = timelineContentInsetX(contentWidth, _viewportWidth);
    final focalContentX =
        durationToContentX(focalTime, widget.duration, contentWidth);
    final scroll = clampScrollPx(
      focalContentX - focalViewportX + inset,
      contentWidth,
      _viewportWidth,
    );
    setState(() {
      _zoom = zoom;
      _scrollPx = scroll;
    });
  }

  void _zoomByFactor(double factor) {
    final focalX = _viewportXFor(widget.playhead).clamp(0.0, _viewportWidth);
    _setZoomAround(
      nextZoom: _zoom * factor,
      focalTime: widget.playhead,
      focalViewportX: focalX,
    );
  }

  String _formatZoomLabel(double zoom) {
    if (zoom >= 10) return '${zoom.round()}x';
    if (zoom < 1) return '${zoom.toStringAsFixed(2)}x';
    return '${zoom.toStringAsFixed(1)}x';
  }

  double _distanceBetweenPointers() {
    final points = _pointers.values.toList(growable: false);
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  Offset _midpointBetweenPointers() {
    final points = _pointers.values.toList(growable: false);
    return Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
  }

  void _beginPinch() {
    final distance = _distanceBetweenPointers();
    if (distance < 1) return;
    final mid = _midpointBetweenPointers();
    final focalX = mid.dx.clamp(0.0, _viewportWidth);
    _pinchStartDistance = distance;
    _pinchStartZoom = _zoom;
    _pinchFocalTime = _timeAtViewportX(focalX);
  }

  void _updatePinch() {
    final startDistance = _pinchStartDistance;
    if (startDistance == null || startDistance < 1) {
      _beginPinch();
      return;
    }
    final distance = _distanceBetweenPointers();
    if (distance < 1) return;
    final scale = distance / startDistance;
    final mid = _midpointBetweenPointers();
    final focalX = mid.dx.clamp(0.0, _viewportWidth);
    _setZoomAround(
      nextZoom: _pinchStartZoom * scale,
      focalTime: _pinchFocalTime,
      focalViewportX: focalX,
    );
  }

  TextOverlay? _overlayAt(double viewportX) {
    for (final overlay in widget.overlays.reversed) {
      final startX = _viewportXFor(overlay.start);
      final endX = _viewportXFor(overlay.end);
      if (viewportX >= startX && viewportX <= endX) {
        return overlay;
      }
    }
    return null;
  }

  TimelineDragTarget _hitTest(Offset local) {
    final x = local.dx.clamp(0.0, _viewportWidth);
    final yRatio = local.dy / _timelineHeight;
    final inTextTrack = yRatio >= _textTrackTop;
    final inVideoTrack = yRatio <= _videoTrackBottom;

    final playheadX = _viewportXFor(widget.playhead);
    if (nearX(x, playheadX, threshold: playheadHitWidth)) {
      return TimelineDragTarget.scrubPlayhead;
    }

    // Text track: resize handles + drag-to-move.
    if (inTextTrack) {
      TextOverlay? selected;
      if (widget.selectedOverlayId != null) {
        for (final overlay in widget.overlays) {
          if (overlay.id == widget.selectedOverlayId) {
            selected = overlay;
            break;
          }
        }
      }
      if (selected != null) {
        final startX = _viewportXFor(selected.start);
        final endX = _viewportXFor(selected.end);
        _dragOverlay = selected;
        _overlayAnchorStart = selected.start;
        _overlayAnchorEnd = selected.end;
        if (nearX(x, startX)) return TimelineDragTarget.overlayStart;
        if (nearX(x, endX)) return TimelineDragTarget.overlayEnd;
        if (x >= startX && x <= endX) {
          widget.onOverlaySelected?.call(selected);
          return TimelineDragTarget.overlayMove;
        }
      }

      final overlay = _overlayAt(x);
      if (overlay != null) {
        widget.onOverlaySelected?.call(overlay);
        final startX = _viewportXFor(overlay.start);
        final endX = _viewportXFor(overlay.end);
        _dragOverlay = overlay;
        _overlayAnchorStart = overlay.start;
        _overlayAnchorEnd = overlay.end;
        if (nearX(x, startX)) return TimelineDragTarget.overlayStart;
        if (nearX(x, endX)) return TimelineDragTarget.overlayEnd;
        return TimelineDragTarget.overlayMove;
      }
    }

    // Video track: trim handles only.
    if (inVideoTrack) {
      final trimStartX = _viewportXFor(widget.trimStart);
      final trimEndX = _viewportXFor(widget.trimEnd);
      if (nearX(x, trimStartX)) return TimelineDragTarget.trimStart;
      if (nearX(x, trimEndX)) return TimelineDragTarget.trimEnd;
    }

    return TimelineDragTarget.panTimeline;
  }

  void _beginSingle(Offset local) {
    final x = local.dx.clamp(0.0, _viewportWidth);
    _didMove = false;
    _pointerDownLocal = local;
    _lastSingleLocal = local;
    _dragTarget = _hitTest(local);
    _panPinnedPlayheadX =
        _viewportXFor(widget.playhead).clamp(0.0, _viewportWidth);
    _lockPlayheadViewportX = _dragTarget == TimelineDragTarget.panTimeline;

    if (_dragTarget == TimelineDragTarget.scrubPlayhead) {
      widget.onPlayheadChanged(_timeAtViewportX(x, snap: false));
    }
  }

  void _updateSingle(Offset local) {
    final previous = _lastSingleLocal ?? local;
    final delta = local - previous;
    _lastSingleLocal = local;
    if (delta.dx.abs() > 0.5 || delta.dy.abs() > 0.5) {
      _didMove = true;
    }
    final x = local.dx.clamp(0.0, _viewportWidth);

    switch (_dragTarget) {
      case TimelineDragTarget.scrubPlayhead:
        widget.onPlayheadChanged(_timeAtViewportX(x, snap: false));
        _ensurePlayheadVisible();
      case TimelineDragTarget.panTimeline:
        // Update scroll first, then report the time under the pinned X.
        // Keep painting at `_panPinnedPlayheadX` until the gesture ends so the
        // playhead does not flash between old playhead + new scroll frames.
        final nextScroll = clampScrollPx(
          _scrollPx - delta.dx,
          _contentWidth,
          _viewportWidth,
        );
        if (nextScroll == _scrollPx) {
          // Hit scroll edge — playhead time under the pin does not change.
          return;
        }
        setState(() {
          _scrollPx = nextScroll;
          _lockPlayheadViewportX = true;
        });
        widget.onPlayheadChanged(
          _timeAtViewportX(_panPinnedPlayheadX, snap: false),
        );
      case TimelineDragTarget.trimStart:
        final t = _timeAtViewportX(x);
        final maxStart = widget.trimEnd - minTrimDuration;
        widget.onTrimStartChanged(clampDuration(t, Duration.zero, maxStart));
      case TimelineDragTarget.trimEnd:
        final t = _timeAtViewportX(x);
        final minEnd = widget.trimStart + minTrimDuration;
        widget.onTrimEndChanged(clampDuration(t, minEnd, widget.duration));
      case TimelineDragTarget.overlayStart:
        final overlay = _dragOverlay;
        if (overlay == null) return;
        final t = _timeAtViewportX(x);
        final maxStart = overlay.end - minOverlayDuration;
        widget.onOverlayChanged(
          overlay.copyWith(start: clampDuration(t, Duration.zero, maxStart)),
        );
      case TimelineDragTarget.overlayEnd:
        final overlay = _dragOverlay;
        if (overlay == null) return;
        final t = _timeAtViewportX(x);
        final minEnd = overlay.start + minOverlayDuration;
        widget.onOverlayChanged(
          overlay.copyWith(end: clampDuration(t, minEnd, widget.duration)),
        );
      case TimelineDragTarget.overlayMove:
        final overlay = _dragOverlay;
        final anchorStart = _overlayAnchorStart;
        final anchorEnd = _overlayAnchorEnd;
        final downLocal = _pointerDownLocal;
        if (overlay == null ||
            anchorStart == null ||
            anchorEnd == null ||
            downLocal == null) {
          return;
        }
        final msPerPx = widget.duration.inMilliseconds / _contentWidth;
        final totalDeltaMs =
            ((x - downLocal.dx) * msPerPx).round();
        final span = anchorEnd - anchorStart;
        var nextStart =
            Duration(milliseconds: anchorStart.inMilliseconds + totalDeltaMs);
        var nextEnd = nextStart + span;
        if (nextStart < Duration.zero) {
          nextStart = Duration.zero;
          nextEnd = span;
        }
        if (nextEnd > widget.duration) {
          nextEnd = widget.duration;
          nextStart = nextEnd - span;
        }
        widget.onOverlayChanged(
          overlay.copyWith(start: nextStart, end: nextEnd),
        );
    }
  }

  void _endSingle() {
    if (!_didMove &&
        !_isPinching &&
        _dragTarget == TimelineDragTarget.panTimeline &&
        _pointerDownLocal != null) {
      final x = _pointerDownLocal!.dx.clamp(0.0, _viewportWidth);
      widget.onPlayheadChanged(_timeAtViewportX(x));
    } else if (_didMove && _dragTarget == TimelineDragTarget.panTimeline) {
      widget.onPlayheadChanged(_timeAtViewportX(_panPinnedPlayheadX));
    } else if (_didMove &&
        _dragTarget == TimelineDragTarget.scrubPlayhead &&
        _lastSingleLocal != null) {
      final x = _lastSingleLocal!.dx.clamp(0.0, _viewportWidth);
      widget.onPlayheadChanged(_timeAtViewportX(x));
    }
    _dragOverlay = null;
    _overlayAnchorStart = null;
    _overlayAnchorEnd = null;
    _pointerDownLocal = null;
    _lastSingleLocal = null;
    _didMove = false;
    _dragTarget = TimelineDragTarget.panTimeline;
    if (_lockPlayheadViewportX) {
      setState(() => _lockPlayheadViewportX = false);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _beginPinch();
      return;
    }
    if (_pointers.length == 1) {
      _beginSingle(event.localPosition);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      _updatePinch();
      return;
    }
    _updateSingle(event.localPosition);
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length >= 2) {
      _beginPinch();
      return;
    }
    if (_pointers.length == 1) {
      // Dropped out of pinch → resume single-finger from remaining pointer.
      _pinchStartDistance = null;
      final remaining = _pointers.values.first;
      _beginSingle(remaining);
      return;
    }
    _pinchStartDistance = null;
    _endSingle();
  }

  @override
  void didUpdateWidget(covariant TimelineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _zoom = 1.0;
      _scrollPx = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.duration == Duration.zero) {
      return const SizedBox(height: 120);
    }

    final visibleStart = _timeAtViewportX(0);
    final visibleEnd = _timeAtViewportX(_viewportWidth);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.onTogglePlay != null) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: widget.isPlaying ? 'Pause' : 'Play',
                  onPressed: widget.onTogglePlay,
                  icon: Icon(
                    widget.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 26,
                    color: AppTheme.accent,
                  ),
                ),
                const SizedBox(width: 2),
              ],
              Text(
                formatDuration(widget.playhead),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Zoom out',
                onPressed: _zoom <= minTimelineZoom
                    ? null
                    : () => _zoomByFactor(1 / 1.4),
                icon: const Icon(Icons.remove, size: 18),
              ),
              Text(
                _formatZoomLabel(_zoom),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Zoom in',
                onPressed:
                    _zoom >= maxTimelineZoom ? null : () => _zoomByFactor(1.4),
                icon: const Icon(Icons.add, size: 18),
              ),
              const SizedBox(width: 4),
              Text(
                _zoom > 1.01
                    ? '${formatDuration(visibleStart)} – ${formatDuration(visibleEnd)}'
                    : formatDuration(widget.duration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              _viewportWidth = constraints.maxWidth;
              _scrollPx =
                  clampScrollPx(_scrollPx, _contentWidth, _viewportWidth);

              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                child: SizedBox(
                  height: _timelineHeight,
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        duration: widget.duration,
                        trimStart: widget.trimStart,
                        trimEnd: widget.trimEnd,
                        overlays: widget.overlays,
                        playhead: widget.playhead,
                        playheadViewportX: _lockPlayheadViewportX
                            ? _panPinnedPlayheadX
                            : null,
                        selectedOverlayId: widget.selectedOverlayId,
                        scrollPx: _scrollPx,
                        contentWidth: _contentWidth,
                        contentInsetX: _contentInsetX,
                        zoom: _zoom,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.duration,
    required this.trimStart,
    required this.trimEnd,
    required this.overlays,
    required this.playhead,
    required this.scrollPx,
    required this.contentWidth,
    required this.contentInsetX,
    required this.zoom,
    this.playheadViewportX,
    this.selectedOverlayId,
  });

  final Duration duration;
  final Duration trimStart;
  final Duration trimEnd;
  final List<TextOverlay> overlays;
  final Duration playhead;
  /// When set (pan scrub), draw the playhead at this fixed viewport X.
  final double? playheadViewportX;
  final double scrollPx;
  final double contentWidth;
  final double contentInsetX;
  final double zoom;
  final String? selectedOverlayId;

  double _x(Duration d) {
    return durationToContentX(d, duration, contentWidth) -
        scrollPx +
        contentInsetX;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final trackLeft = contentInsetX;
    final trackWidth = contentWidth.clamp(0.0, size.width);
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        trackLeft,
        size.height * 0.18,
        trackWidth,
        size.height * 0.28,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );

    final tickCount = (8 * zoom).round().clamp(4, 48);
    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var i = 0; i <= tickCount; i++) {
      final t = Duration(
        milliseconds: ((duration.inMilliseconds / tickCount) * i).round(),
      );
      final x = _x(t);
      if (x < -2 || x > size.width + 2) continue;
      canvas.drawLine(
        Offset(x, size.height * 0.18),
        Offset(x, size.height * 0.46),
        tickPaint,
      );
    }

    canvas.drawRect(
      Rect.fromLTRB(_x(trimStart), 0, _x(trimEnd), size.height * 0.52),
      Paint()..color = AppTheme.accent.withValues(alpha: 0.18),
    );

    _drawHandle(
      canvas,
      _x(trimStart),
      top: 0,
      bottom: size.height * _videoTrackBottom,
      color: AppTheme.accent,
    );
    _drawHandle(
      canvas,
      _x(trimEnd),
      top: 0,
      bottom: size.height * _videoTrackBottom,
      color: AppTheme.accent,
    );

    final textTrackTop = size.height * _textTrackTop;
    final textTrackBottom = size.height;

    for (final overlay in overlays) {
      final selected = overlay.id == selectedOverlayId;
      final left = _x(overlay.start);
      final right = _x(overlay.end);
      if (right < 0 || left > size.width) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, textTrackTop, right, textTrackBottom),
          const Radius.circular(4),
        ),
        Paint()
          ..color = selected
              ? AppTheme.accent
              : Colors.white.withValues(alpha: 0.45),
      );
      if (selected) {
        _drawHandle(
          canvas,
          left,
          top: textTrackTop,
          bottom: textTrackBottom,
          color: Colors.white,
        );
        _drawHandle(
          canvas,
          right,
          top: textTrackTop,
          bottom: textTrackBottom,
          color: Colors.white,
        );
      }
    }

    final headX = playheadViewportX ?? _x(playhead);
    canvas.drawLine(
      Offset(headX, 0),
      Offset(headX, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset(headX, size.height * 0.08),
      5,
      Paint()..color = Colors.white,
    );
  }

  void _drawHandle(
    Canvas canvas,
    double x, {
    required double top,
    required double bottom,
    required Color color,
  }) {
    final trackHeight = bottom - top;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, top + trackHeight / 2),
          width: 5,
          height: trackHeight * 0.75,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.trimStart != trimStart ||
        oldDelegate.trimEnd != trimEnd ||
        oldDelegate.playhead != playhead ||
        oldDelegate.playheadViewportX != playheadViewportX ||
        oldDelegate.scrollPx != scrollPx ||
        oldDelegate.contentWidth != contentWidth ||
        oldDelegate.contentInsetX != contentInsetX ||
        oldDelegate.zoom != zoom ||
        oldDelegate.selectedOverlayId != selectedOverlayId ||
        oldDelegate.overlays != overlays;
  }
}
