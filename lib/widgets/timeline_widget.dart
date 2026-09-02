import 'dart:math' as math;

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:flutter/material.dart';

/// Height of the fixed clip track at the top; it never scrolls away.
const _videoTrackHeight = 58.0;

/// Visible gap between split clip blocks on the timeline.
const _segmentGap = 2.0;

/// Fixed filmstrip tile width — only as many tiles as fit are drawn per segment.
const _filmstripTileWidth = 48.0;

/// Paint/hit-test bounds for one segment block on the packed timeline.
({double left, double right}) segmentBlockBounds({
  required double rawLeft,
  required double rawRight,
  required bool gapBefore,
  required bool gapAfter,
}) {
  var left = rawLeft;
  var right = rawRight;

  if (gapAfter) right -= _segmentGap / 2;
  if (gapBefore) left += _segmentGap / 2;

  // Narrow blocks (common right after a split at default zoom) must still
  // paint filmstrip — gap insets are dropped instead of skipping the segment.
  if (right <= left) {
    left = rawLeft;
    right = rawRight;
  }
  if (right <= left) {
    right = left + 1;
  }

  return (left: left, right: right);
}

/// One text overlay per lane, stacked under the clip track.
const _laneHeight = 26.0;
const _laneGap = 4.0;
const _laneStride = _laneHeight + _laneGap;

/// Past this the lane area scrolls instead of growing.
const _maxVisibleLanes = 3;

/// Travel before a drag commits to scrolling lanes or panning time.
const _axisSlop = 3.0;

/// Finger travel still treated as a tap for clip-segment selection.
const _segmentTapSlop = 12.0;

enum TimelineDragTarget {
  panTimeline,
  scrollLanes,
  trimStart,
  trimEnd,
  overlayStart,
  overlayEnd,
  overlayMove,
}

/// Interactive timeline with pinch-zoom and a fixed centre playhead: the strip
/// scrolls under the indicator instead of the indicator moving along the strip.
///
/// Each overlay owns a lane below the clip track, and the lane area scrolls
/// vertically once there are more overlays than fit.
class TimelineWidget extends StatefulWidget {
  const TimelineWidget({
    super.key,
    required this.duration,
    required this.trimStart,
    required this.trimEnd,
    required this.segments,
    required this.overlays,
    required this.playhead,
    required this.onPlayheadChanged,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
    required this.onOverlayChanged,
    this.onOverlaySelected,
    this.onSegmentSelected,
    this.selectedOverlayId,
    this.selectedSegmentId,
    this.isPlaying = false,
    this.onTogglePlay,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.filmstripFrames = const [],
  });

  final Duration duration;
  final Duration trimStart;
  final Duration trimEnd;
  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final Duration playhead;
  final ValueChanged<Duration> onPlayheadChanged;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  final ValueChanged<TextOverlay> onOverlayChanged;
  final ValueChanged<TextOverlay>? onOverlaySelected;
  final ValueChanged<ClipSegment>? onSegmentSelected;
  final String? selectedOverlayId;
  final String? selectedSegmentId;
  final bool isPlaying;
  final VoidCallback? onTogglePlay;

  /// Vertical drags on the transport row, so it doubles as a grab handle for
  /// collapsing the editor chrome.
  final GestureDragUpdateCallback? onHandleDragUpdate;
  final GestureDragEndCallback? onHandleDragEnd;
  final List<TimelineFilmstripFrame> filmstripFrames;

  @override
  State<TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends State<TimelineWidget> {
  double _zoom = 1.0;
  double _viewportWidth = 1;
  double _lanesScrollY = 0;

  TimelineDragTarget _dragTarget = TimelineDragTarget.panTimeline;
  TextOverlay? _dragOverlay;
  ClipSegment? _tapSegment;
  Duration? _overlayAnchorStart;
  Duration? _overlayAnchorEnd;

  /// Resolved on first travel: every drag is either a vertical lane scroll or
  /// the horizontal action the hit test picked.
  Axis? _dragAxis;

  /// Selection is announced once the gesture proves it is not a lane scroll.
  bool _selectionAnnounced = false;

  bool _didMove = false;
  Offset? _pointerDownLocal;
  Offset? _lastSingleLocal;
  Duration? _panAnchorSequenceTime;

  /// Active pointer positions in local coords (Listener-based multi-touch).
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartZoom = 1.0;

  double get _contentWidth => _viewportWidth * _zoom;
  double get _contentInsetX => timelineContentInsetX(_viewportWidth);
  bool get _isPinching => _pointers.length >= 2;

  /// An empty timeline still shows one lane slot so the area reads as a track.
  double get _lanesContentHeight =>
      (widget.overlays.isEmpty ? 1 : widget.overlays.length) * _laneStride;

  double get _lanesViewportHeight =>
      _lanesContentHeight.clamp(0.0, _maxVisibleLanes * _laneStride);

  double get _maxLanesScroll =>
      (_lanesContentHeight - _lanesViewportHeight).clamp(0.0, double.infinity);

  bool get _lanesScrollable => _maxLanesScroll > 0;

  double get _bodyHeight => _videoTrackHeight + _lanesViewportHeight;

  Duration get _sequenceDuration {
    final kept = totalKeptDuration(widget.segments);
    if (kept > Duration.zero) return kept;
    return widget.duration;
  }

  Duration get _sequencePlayhead =>
      timelinePlayheadFromSource(widget.segments, widget.playhead);

  /// Derived, never stored: the playhead defines where the strip sits.
  double get _scrollPx => scrollPxForPlayhead(
    playhead: _sequencePlayhead,
    total: _sequenceDuration,
    contentWidth: _contentWidth,
  );

  Duration _sequenceTimeAtViewportX(double x, {bool snap = true}) {
    final time = viewportXToDuration(
      x: x,
      scrollPx: _scrollPx,
      total: _sequenceDuration,
      contentWidth: _contentWidth,
      contentInsetX: _contentInsetX,
    );
    return snap ? snapDuration(time) : time;
  }

  Duration _timeAtViewportX(double x, {bool snap = true}) {
    final sequenceTime = _sequenceTimeAtViewportX(x, snap: snap);
    return exportTimeToSourceTime(widget.segments, sequenceTime);
  }

  double _viewportXForSequence(Duration sequenceTime) {
    return durationToViewportX(
      time: sequenceTime,
      scrollPx: _scrollPx,
      total: _sequenceDuration,
      contentWidth: _contentWidth,
      contentInsetX: _contentInsetX,
    );
  }

  double? _viewportXForSource(Duration sourceTime) {
    final export = sourceTimeToExportTime(widget.segments, sourceTime);
    if (export == null) return null;
    return _viewportXForSequence(export);
  }

  /// Matches [_TimelinePainter._paintClipTrack] geometry for reliable taps.
  ClipSegment? _segmentAtViewportX(double x) {
    if (widget.segments.isEmpty) return null;

    var sequenceOffset = Duration.zero;
    for (var i = 0; i < widget.segments.length; i++) {
      final segment = widget.segments[i];
      if (segment.duration <= Duration.zero) {
        sequenceOffset += segment.duration;
        continue;
      }

      final rawLeft = _viewportXForSequence(sequenceOffset);
      final rawRight = _viewportXForSequence(sequenceOffset + segment.duration);
      final bounds = segmentBlockBounds(
        rawLeft: rawLeft,
        rawRight: rawRight,
        gapBefore: i > 0,
        gapAfter: i < widget.segments.length - 1,
      );
      if (x >= bounds.left && x <= bounds.right) return segment;
      sequenceOffset += segment.duration;
    }
    return null;
  }

  /// Zoom always pivots on the playhead — it is the one point that cannot move.
  void _setZoom(double nextZoom) {
    final zoom = nextZoom.clamp(minTimelineZoom, maxTimelineZoom);
    if (zoom == _zoom) return;
    setState(() => _zoom = zoom);
  }

  void _zoomByFactor(double factor) => _setZoom(_zoom * factor);

  void _scrollLanesBy(double delta) {
    final next = (_lanesScrollY + delta).clamp(0.0, _maxLanesScroll);
    if (next == _lanesScrollY) return;
    setState(() => _lanesScrollY = next);
  }

  /// Brings [index]'s lane fully into view — used when a new layer is added.
  void _revealLane(int index) {
    if (index < 0) return;
    final top = index * _laneStride;
    final bottom = top + _laneHeight;
    var next = _lanesScrollY;
    if (top < next) {
      next = top;
    } else if (bottom > next + _lanesViewportHeight) {
      next = bottom - _lanesViewportHeight;
    }
    next = next.clamp(0.0, _maxLanesScroll);
    if (next != _lanesScrollY) {
      setState(() => _lanesScrollY = next);
    }
  }

  int _laneIndexOf(String? overlayId) {
    if (overlayId == null) return -1;
    return widget.overlays.indexWhere((o) => o.id == overlayId);
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

  void _beginPinch() {
    final distance = _distanceBetweenPointers();
    if (distance < 1) return;
    _pinchStartDistance = distance;
    _pinchStartZoom = _zoom;
  }

  void _updatePinch() {
    final startDistance = _pinchStartDistance;
    if (startDistance == null || startDistance < 1) {
      _beginPinch();
      return;
    }
    final distance = _distanceBetweenPointers();
    if (distance < 1) return;
    _setZoom(_pinchStartZoom * distance / startDistance);
  }

  /// The overlay whose lane contains [local], or null for the clip track and
  /// empty lane space.
  TextOverlay? _overlayInLaneAt(Offset local) {
    if (local.dy < _videoTrackHeight) return null;
    final contentY = local.dy - _videoTrackHeight + _lanesScrollY;
    if (contentY < 0) return null;
    final index = contentY ~/ _laneStride;
    if (index < 0 || index >= widget.overlays.length) return null;
    return widget.overlays[index];
  }

  TimelineDragTarget _hitTest(Offset local) {
    final x = local.dx.clamp(0.0, _viewportWidth);

    // No playhead target: it is fixed at the centre, so grabbing it would be
    // indistinguishable from panning the strip underneath it.

    _dragOverlay = null;
    _tapSegment = null;

    // Touching anywhere in a lane targets its layer, so rows can be picked
    // even where the bar does not reach. Selection is deferred until the
    // gesture proves it is not a lane scroll.
    final overlay = _overlayInLaneAt(local);
    if (overlay != null) {
      _dragOverlay = overlay;
      _overlayAnchorStart = overlay.start;
      _overlayAnchorEnd = overlay.end;

      final span = overlayTimelineSpan(overlay, widget.segments);
      if (span != null) {
        final startX = _viewportXForSequence(span.start);
        final endX = _viewportXForSequence(span.end);
        if (nearX(x, startX)) {
          return TimelineDragTarget.overlayStart;
        }
        if (nearX(x, endX)) {
          return TimelineDragTarget.overlayEnd;
        }
        if (x >= startX && x <= endX) {
          return TimelineDragTarget.overlayMove;
        }
      }
    }

    // Clip track: trim handles, then segment selection.
    if (local.dy < _videoTrackHeight) {
      final trimStartX = _viewportXForSequence(Duration.zero);
      final trimEndX = _viewportXForSequence(_sequenceDuration);
      if (nearX(x, trimStartX)) return TimelineDragTarget.trimStart;
      if (nearX(x, trimEndX)) return TimelineDragTarget.trimEnd;

      _tapSegment = _segmentAtViewportX(x);
    }

    return TimelineDragTarget.panTimeline;
  }

  void _beginSingle(Offset local) {
    _didMove = false;
    _dragAxis = null;
    _selectionAnnounced = false;
    _pointerDownLocal = local;
    _lastSingleLocal = local;
    _panAnchorSequenceTime = null;
    _dragTarget = _hitTest(local);
    if (_dragTarget == TimelineDragTarget.panTimeline) {
      _panAnchorSequenceTime = _sequenceTimeAtViewportX(_viewportWidth / 2);
    }
  }

  /// Vertical wins only when there is something to scroll, so the gesture is
  /// never swallowed by a lane area that cannot move.
  ///
  /// This applies to layer bars too: with lanes packed edge to edge there is
  /// no empty strip left to start a scroll from.
  Axis? _resolveDragAxis(Offset local) {
    final down = _pointerDownLocal;
    if (down == null) return Axis.horizontal;
    final travel = local - down;
    if (travel.distance < _axisSlop) return null;
    if (travel.dy.abs() > travel.dx.abs() && _lanesScrollable) {
      return Axis.vertical;
    }
    return Axis.horizontal;
  }

  void _updateSingle(Offset local) {
    final previous = _lastSingleLocal ?? local;
    final delta = local - previous;
    if (delta.dx.abs() > 0.5 || delta.dy.abs() > 0.5) {
      _didMove = true;
    }

    if (_dragAxis == null) {
      final axis = _resolveDragAxis(local);
      if (axis == null) return; // still inside the slop
      _dragAxis = axis;
      if (axis == Axis.vertical) {
        _dragTarget = TimelineDragTarget.scrollLanes;
      } else {
        _announceSelection();
      }
    }

    _lastSingleLocal = local;
    final x = local.dx.clamp(0.0, _viewportWidth);

    switch (_dragTarget) {
      case TimelineDragTarget.scrollLanes:
        _scrollLanesBy(-delta.dy);
      case TimelineDragTarget.panTimeline:
        final down = _pointerDownLocal;
        final anchor = _panAnchorSequenceTime;
        if (down == null || anchor == null) return;
        final msPerPx = _sequenceDuration.inMilliseconds / _contentWidth;
        final totalDeltaMs = ((local.dx - down.dx) * msPerPx).round();
        final nextMs = (anchor.inMilliseconds - totalDeltaMs)
            .clamp(0, _sequenceDuration.inMilliseconds);
        widget.onPlayheadChanged(
          exportTimeToSourceTime(
            widget.segments,
            Duration(milliseconds: nextMs),
          ),
        );
      case TimelineDragTarget.trimStart:
        if (widget.segments.isEmpty) return;
        final t = _timeAtViewportX(x);
        final maxStart = widget.segments.first.end - minTrimDuration;
        widget.onTrimStartChanged(clampDuration(t, Duration.zero, maxStart));
      case TimelineDragTarget.trimEnd:
        if (widget.segments.isEmpty) return;
        final t = _timeAtViewportX(x);
        final minEnd = widget.segments.last.start + minTrimDuration;
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
        final exportStart = sourceTimeToExportTime(widget.segments, anchorStart);
        final exportEnd = overlayExportTimeForEnd(widget.segments, anchorEnd);
        if (exportStart == null || exportEnd == null) return;

        final msPerPx = _sequenceDuration.inMilliseconds / _contentWidth;
        final totalDeltaMs = ((x - downLocal.dx) * msPerPx).round();
        final sourceSpanMs = anchorEnd.inMilliseconds - anchorStart.inMilliseconds;
        final exportSpanMs = exportEnd.inMilliseconds - exportStart.inMilliseconds;

        var nextExportStart = Duration(
          milliseconds: exportStart.inMilliseconds + totalDeltaMs,
        );
        if (nextExportStart < Duration.zero) {
          nextExportStart = Duration.zero;
        }
        final maxExportStartMs = _sequenceDuration.inMilliseconds - exportSpanMs;
        if (nextExportStart.inMilliseconds > maxExportStartMs) {
          nextExportStart = Duration(milliseconds: maxExportStartMs);
        }

        var nextStart = exportTimeToSourceTime(widget.segments, nextExportStart);
        var nextEnd = Duration(
          milliseconds: nextStart.inMilliseconds + sourceSpanMs,
        );
        if (nextEnd > widget.duration) {
          nextEnd = widget.duration;
          nextStart = Duration(milliseconds: nextEnd.inMilliseconds - sourceSpanMs);
          if (nextStart < Duration.zero) {
            nextStart = Duration.zero;
            nextEnd = Duration(milliseconds: sourceSpanMs.clamp(0, widget.duration.inMilliseconds));
          }
        }
        widget.onOverlayChanged(
          overlay.copyWith(start: nextStart, end: nextEnd),
        );
    }
  }

  void _announceSelection() {
    final overlay = _dragOverlay;
    if (overlay == null || _selectionAnnounced) return;
    _selectionAnnounced = true;
    widget.onOverlaySelected?.call(overlay);
  }

  void _endSingle() {
    final down = _pointerDownLocal;
    final up = _lastSingleLocal;
    if (_isPinching || down == null) {
      _resetSingleGesture();
      return;
    }

    final travel = up != null ? (up - down).distance : 0.0;
    final tapped = !_didMove || travel < _segmentTapSlop;
    final onClipTrack = down.dy < _videoTrackHeight;

    if (tapped && _dragOverlay != null) {
      _announceSelection();
    } else if (tapped && onClipTrack) {
      final segment = _segmentAtViewportX(down.dx) ?? _tapSegment;
      if (segment != null) {
        widget.onSegmentSelected?.call(segment);
      } else if (_dragTarget == TimelineDragTarget.panTimeline) {
        final x = down.dx.clamp(0.0, _viewportWidth);
        widget.onPlayheadChanged(_timeAtViewportX(x));
      }
    } else if (_dragTarget == TimelineDragTarget.panTimeline) {
      if (tapped) {
        // A tap seeks to what was under the finger; it then slides to centre.
        final x = down.dx.clamp(0.0, _viewportWidth);
        widget.onPlayheadChanged(_timeAtViewportX(x));
      } else if (_didMove) {
        widget.onPlayheadChanged(snapDuration(widget.playhead));
      }
    }

    _resetSingleGesture();
  }

  void _resetSingleGesture() {
    _dragOverlay = null;
    _tapSegment = null;
    _overlayAnchorStart = null;
    _overlayAnchorEnd = null;
    _pointerDownLocal = null;
    _lastSingleLocal = null;
    _panAnchorSequenceTime = null;
    _dragAxis = null;
    _selectionAnnounced = false;
    _didMove = false;
    _dragTarget = TimelineDragTarget.panTimeline;
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
    }

    // Deleting layers can leave the scroll past the end.
    if (_lanesScrollY > _maxLanesScroll) {
      _lanesScrollY = _maxLanesScroll;
    }

    final gainedLayer = widget.overlays.length > oldWidget.overlays.length;
    final selectionMoved =
        widget.selectedOverlayId != oldWidget.selectedOverlayId;
    if (gainedLayer || selectionMoved) {
      _revealLane(_laneIndexOf(widget.selectedOverlayId));
    }
  }

  /// Play button, times and zoom controls.
  ///
  /// Split into two groups instead of one flat [Row] with a [Spacer]: a Spacer
  /// claims its share of the free space unconditionally, which starved the
  /// range label and overflowed the row once the system text scale grew.
  Widget _buildTransportRow(Duration visibleStart, Duration visibleEnd) {
    final labelStyle = Theme.of(context).textTheme.bodySmall;

    return MediaQuery.withClampedTextScaling(
      // A dense numeric strip; past this it cannot fit a small phone at all.
      maxScaleFactor: 1.3,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
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
              Text(formatDuration(_sequencePlayhead), style: labelStyle),
            ],
          ),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Zoom out',
                  onPressed: _zoom <= minTimelineZoom
                      ? null
                      : () => _zoomByFactor(1 / 1.4),
                  icon: const Icon(Icons.remove, size: 18),
                ),
                Text(_formatZoomLabel(_zoom), style: labelStyle),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Zoom in',
                  onPressed: _zoom >= maxTimelineZoom
                      ? null
                      : () => _zoomByFactor(1.4),
                  icon: const Icon(Icons.add, size: 18),
                ),
                const SizedBox(width: 4),
                // Last to be given room, first to give it back.
                Flexible(
                  child: Text(
                    _zoom > 1.01
                        ? formatTimelineRange(visibleStart, visibleEnd)
                        : formatDuration(_sequenceDuration),
                    style: labelStyle,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sequenceDuration == Duration.zero) {
      return const SizedBox(height: 120);
    }

    final visibleStart = _sequenceTimeAtViewportX(0);
    final visibleEnd = _sequenceTimeAtViewportX(_viewportWidth);

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
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: widget.onHandleDragUpdate,
            onVerticalDragEnd: widget.onHandleDragEnd,
            child: _buildTransportRow(visibleStart, visibleEnd),
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              _viewportWidth = constraints.maxWidth;

              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                child: SizedBox(
                  height: _bodyHeight,
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        sequenceDuration: _sequenceDuration,
                        sequencePlayhead: _sequencePlayhead,
                        segments: widget.segments,
                        overlays: widget.overlays,
                        filmstripFrames: widget.filmstripFrames,
                        selectedOverlayId: widget.selectedOverlayId,
                        selectedSegmentId: widget.selectedSegmentId,
                        scrollPx: _scrollPx,
                        contentWidth: _contentWidth,
                        contentInsetX: _contentInsetX,
                        zoom: _zoom,
                        lanesScrollY: _lanesScrollY,
                        lanesContentHeight: _lanesContentHeight,
                        laneLabelStyle: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.background,
                        ),
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
    required this.sequenceDuration,
    required this.sequencePlayhead,
    required this.segments,
    required this.overlays,
    required this.scrollPx,
    required this.contentWidth,
    required this.contentInsetX,
    required this.zoom,
    required this.lanesScrollY,
    required this.lanesContentHeight,
    required this.laneLabelStyle,
    this.filmstripFrames = const [],
    this.selectedOverlayId,
    this.selectedSegmentId,
  });

  final Duration sequenceDuration;
  final Duration sequencePlayhead;
  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final double scrollPx;
  final double contentWidth;
  final double contentInsetX;
  final double zoom;
  final double lanesScrollY;
  final double lanesContentHeight;
  final TextStyle laneLabelStyle;
  final List<TimelineFilmstripFrame> filmstripFrames;
  final String? selectedOverlayId;
  final String? selectedSegmentId;

  double _x(Duration sequenceTime) {
    return durationToContentX(sequenceTime, sequenceDuration, contentWidth) -
        scrollPx +
        contentInsetX;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintClipTrack(canvas, size);
    _paintLanes(canvas, size);
    _paintPlayhead(canvas, size);
  }

  void _paintClipTrack(Canvas canvas, Size size) {
    if (segments.isEmpty) return;

    final trimTop = _videoTrackHeight * 0.12;
    final trimBottom = _videoTrackHeight * 0.88;

    final envelopeLeft = _x(Duration.zero);
    final envelopeRight = _x(sequenceDuration);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(envelopeLeft, trimTop, envelopeRight, trimBottom),
        const Radius.circular(5),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.4),
    );

    var sequenceOffset = Duration.zero;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.duration <= Duration.zero) {
        sequenceOffset += segment.duration;
        continue;
      }

      final rawLeft = _x(sequenceOffset);
      final rawRight = _x(sequenceOffset + segment.duration);
      final bounds = segmentBlockBounds(
        rawLeft: rawLeft,
        rawRight: rawRight,
        gapBefore: i > 0,
        gapAfter: i < segments.length - 1,
      );

      final selected = segment.id == selectedSegmentId;
      final rect = Rect.fromLTRB(bounds.left, trimTop, bounds.right, trimBottom);
      final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(4));

      _paintFilmstrip(canvas, rect, segment);

      canvas.drawRRect(
        rounded,
        Paint()
          ..color = selected
              ? AppTheme.accent.withValues(alpha: 0.28)
              : Colors.black.withValues(alpha: 0.12),
      );

      if (selected) {
        canvas.drawRRect(
          rounded,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }

      if (i < segments.length - 1) {
        final dividerX = rawRight;
        canvas.drawLine(
          Offset(dividerX, trimTop + 2),
          Offset(dividerX, trimBottom - 2),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.65)
            ..strokeWidth = 1.5,
        );
      }

      sequenceOffset += segment.duration;
    }

    _drawHandle(
      canvas,
      _x(Duration.zero),
      top: trimTop,
      bottom: trimBottom,
      color: AppTheme.accent,
    );
    _drawHandle(
      canvas,
      _x(sequenceDuration),
      top: trimTop,
      bottom: trimBottom,
      color: AppTheme.accent,
    );
  }

  void _paintLanes(Canvas canvas, Size size) {
    final viewportHeight = size.height - _videoTrackHeight;
    if (viewportHeight <= 0) return;

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, _videoTrackHeight, size.width, viewportHeight),
    );
    canvas.translate(0, _videoTrackHeight - lanesScrollY);

    for (var i = 0; i < overlays.length; i++) {
      final overlay = overlays[i];
      final laneTop = i * _laneStride;
      // Cheap cull: lanes scrolled out of view and clips off either edge.
      if (laneTop - lanesScrollY > viewportHeight ||
          laneTop - lanesScrollY + _laneHeight < 0) {
        continue;
      }

      final selected = overlay.id == selectedOverlayId;
      final ranges = overlayTimelineRanges(overlay, segments);
      if (ranges.isEmpty) continue;

      for (final range in ranges) {
        final exportRange = sourceRangeToExportRange(
          segments,
          range.start,
          range.end,
        );
        if (exportRange == null) continue;

        final left = _x(exportRange.start);
        final right = _x(exportRange.end);
        if (right < 0 || left > size.width) continue;

        final rect = Rect.fromLTRB(left, laneTop, right, laneTop + _laneHeight);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          Paint()
            ..color = selected
                ? AppTheme.accent
                : Colors.white.withValues(alpha: 0.45),
        );
        _paintLaneLabel(canvas, rect, overlay.text);
      }

      if (selected) {
        final span = overlayTimelineSpan(overlay, segments);
        if (span != null) {
          _drawHandle(
            canvas,
            _x(span.start),
            top: laneTop,
            bottom: laneTop + _laneHeight,
            color: Colors.white,
          );
          _drawHandle(
            canvas,
            _x(span.end),
            top: laneTop,
            bottom: laneTop + _laneHeight,
            color: Colors.white,
          );
        }
      }
    }

    canvas.restore();
    _paintLaneScrollbar(canvas, size, viewportHeight);
  }

  /// Names the layer inside its bar so stacked lanes stay distinguishable.
  void _paintLaneLabel(Canvas canvas, Rect rect, String text) {
    const padding = 6.0;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final maxWidth = rect.width - padding * 2;
    if (maxWidth < 16) return;

    final painter = TextPainter(
      text: TextSpan(text: trimmed, style: laneLabelStyle),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    canvas.save();
    canvas.clipRect(rect);
    painter.paint(
      canvas,
      Offset(rect.left + padding, rect.center.dy - painter.height / 2),
    );
    canvas.restore();
    painter.dispose();
  }

  void _paintLaneScrollbar(Canvas canvas, Size size, double viewportHeight) {
    if (lanesContentHeight <= viewportHeight) return;

    final thumbHeight = (viewportHeight * viewportHeight / lanesContentHeight)
        .clamp(18.0, viewportHeight);
    final maxScroll = lanesContentHeight - viewportHeight;
    final progress = (lanesScrollY / maxScroll).clamp(0.0, 1.0);
    final top =
        _videoTrackHeight + progress * (viewportHeight - thumbHeight);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - 3, top, 3, thumbHeight),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.3),
    );
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    // Pinned to the centre by construction: scrollPx is derived from playhead.
    final headX = size.width / 2;
    canvas.drawLine(
      Offset(headX, 0),
      Offset(headX, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset(headX, 5),
      5,
      Paint()..color = Colors.white,
    );
  }

  void _paintFilmstrip(Canvas canvas, Rect rect, ClipSegment segment) {
    if (filmstripFrames.isEmpty || rect.width <= 0 || segment.duration <= Duration.zero) {
      return;
    }

    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
    );

    final tileCount = math.max(1, (rect.width / _filmstripTileWidth).ceil());
    for (var i = 0; i < tileCount; i++) {
      final left = rect.left + i * _filmstripTileWidth;
      if (left >= rect.right) break;

      // Last tile stretches to the segment edge so no black strip remains.
      final width = rect.right - left;
      if (width <= 0) break;

      final sampleX = left + width / 2;
      var centerFraction = (sampleX - rect.left) / rect.width;
      if (i == tileCount - 1) {
        centerFraction = 1.0;
      }
      final sourceMs = segment.start.inMilliseconds +
          (segment.duration.inMilliseconds * centerFraction).round();
      final endMs = segment.end.inMilliseconds - 1;
      final upperMs = endMs >= segment.start.inMilliseconds
          ? endMs
          : segment.start.inMilliseconds;
      final clampedMs = sourceMs.clamp(segment.start.inMilliseconds, upperMs);
      final frame = _nearestFilmstripFrame(
        Duration(milliseconds: clampedMs.toInt()),
      );
      if (frame == null) continue;

      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(left, rect.top, width, rect.height),
        image: frame.image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
      );
    }
    canvas.restore();
  }

  TimelineFilmstripFrame? _nearestFilmstripFrame(Duration sourceTime) {
    TimelineFilmstripFrame? best;
    var bestDeltaMs = 1 << 62;
    for (final frame in filmstripFrames) {
      final deltaMs = (frame.sourceTime - sourceTime).inMilliseconds.abs();
      if (deltaMs < bestDeltaMs) {
        bestDeltaMs = deltaMs;
        best = frame;
      }
    }
    return best;
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
    return oldDelegate.sequenceDuration != sequenceDuration ||
        oldDelegate.sequencePlayhead != sequencePlayhead ||
        oldDelegate.segments != segments ||
        oldDelegate.scrollPx != scrollPx ||
        oldDelegate.contentWidth != contentWidth ||
        oldDelegate.contentInsetX != contentInsetX ||
        oldDelegate.zoom != zoom ||
        oldDelegate.lanesScrollY != lanesScrollY ||
        oldDelegate.lanesContentHeight != lanesContentHeight ||
        oldDelegate.selectedOverlayId != selectedOverlayId ||
        oldDelegate.selectedSegmentId != selectedSegmentId ||
        oldDelegate.filmstripFrames != filmstripFrames ||
        oldDelegate.overlays != overlays;
  }
}
