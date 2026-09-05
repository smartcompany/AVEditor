import 'dart:math' as math;

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/music_timeline_ops.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Height of the fixed clip track at the top; it never scrolls away.
/// Filmstrip on top, source-audio waveform + envelope along the bottom (iMovie).
const _videoFilmstripHeight = 40.0;
const _videoAudioHeight = 30.0;
const _videoTrackHeight = _videoFilmstripHeight + _videoAudioHeight;

/// Background-music lane under the filmstrip (waveform + volume envelope).
const _musicTrackHeight = 44.0;
const _musicTrackGap = 4.0;
const _musicLaneStride = _musicTrackHeight + _musicTrackGap;
const _musicVolumeHitSlop = 12.0;
const _musicFadeHitSlop = 22.0;
/// Keep fade handles clear of the white trim bars (music / wide clips).
const _musicFadeHandleInset = 18.0;

/// CapCut-style end caps: wide, full-lane height, outside the clip time span.
const _overlayHandleWidth = 18.0;
const _overlayHandleOutsetY = 5.0;

/// Visible gap between split clip blocks on the timeline.
const _segmentGap = 2.0;

/// Drawn / tappable bounds for a start or end cap.
///
/// Caps sit **outside** the clip time span (CapCut-style):
/// [atStart] → immediately left of the start edge;
/// otherwise → immediately right of the end edge.
/// Vertically the rect is taller than the lane ([_overlayHandleOutsetY]).
Rect overlayEdgeHandleRect(
  double edgeX, {
  required double top,
  required double bottom,
  required bool atStart,
}) {
  final height = (bottom - top) + _overlayHandleOutsetY * 2;
  final topY = top - _overlayHandleOutsetY;
  final left = atStart ? edgeX - _overlayHandleWidth : edgeX;
  return Rect.fromLTWH(left, topY, _overlayHandleWidth, height);
}

/// Minimum gap kept between fade-in and fade-out knobs on a clip.
const _minFadeHandleGap = 10.0;

/// Narrowest audio bar that still gets interactive fade knobs.
const _minAudioFadeBarWidth = 14.0;

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

/// Shrinks edge inset on short split clips so both fade knobs stay on the bar.
double audioFadeHandleInset(double width) {
  if (width <= _minAudioFadeBarWidth) return width * 0.2;
  final room = (width - _minFadeHandleGap) / 2;
  if (room <= 0) return 0;
  return math.min(_musicFadeHandleInset, room);
}

/// Fade-in / fade-out knob X positions that stay inside [left, right] even on
/// short middle cuts after a multi-way split.
({double inX, double outX}) audioFadeHandleXs({
  required double left,
  required double right,
  required Duration fadeIn,
  required Duration fadeOut,
  required Duration duration,
}) {
  final width = right - left;
  if (width <= 0) return (inX: left, outX: right);

  final spanMs = duration.inMilliseconds.clamp(1, 1 << 31);
  final inset = audioFadeHandleInset(width);
  final inRaw = left + width * (fadeIn.inMilliseconds / spanMs);
  final outRaw = right - width * (fadeOut.inMilliseconds / spanMs);

  final minIn = left + inset;
  final maxOut = right - inset;
  if (maxOut - minIn < _minFadeHandleGap) {
    return (
      inX: left + width * 0.28,
      outX: left + width * 0.72,
    );
  }

  var inX = inRaw.clamp(minIn, maxOut - _minFadeHandleGap);
  var outX = outRaw.clamp(inX + _minFadeHandleGap, maxOut);
  inX = inX.clamp(minIn, outX - _minFadeHandleGap);
  return (inX: inX, outX: outX);
}

/// Text overlays share lanes when they do not overlap in time; overlapping
/// clips are pushed to a new lane below (CapCut-style).
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
  musicMove,
  musicStart,
  musicEnd,
  musicVolume,
  musicFadeIn,
  musicFadeOut,
  videoAudioVolume,
  videoAudioFadeIn,
  videoAudioFadeOut,
}

/// Interactive timeline with pinch-zoom and a fixed centre playhead: the strip
/// scrolls under the indicator instead of the indicator moving along the strip.
///
/// The video track stays pinned. Below it, music lanes then text lanes share one
/// vertical scroll stack (music A/B…, then text). Overlapping clips drop to a
/// new lane of their kind; the stack scrolls once more rows than fit.
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
    this.musicTracks = const [],
    this.musicWaveforms = const {},
    this.onMusicChanged,
    this.onMusicSelected,
    this.selectedMusicId,
    this.onOverlaySelected,
    this.onSegmentSelected,
    this.onSegmentChanged,
    this.selectedOverlayId,
    this.selectedSegmentId,
    this.isPlaying = false,
    this.onTogglePlay,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.filmstripFrames = const [],
    this.sourceAudioWaveform = const [],
    this.hasSourceAudio = false,
  });

  final Duration duration;
  final Duration trimStart;
  final Duration trimEnd;
  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final List<ProjectMusic> musicTracks;

  /// Peak bars keyed by [ProjectMusic.fileName].
  final Map<String, List<double>> musicWaveforms;
  final ValueChanged<ProjectMusic>? onMusicChanged;
  final ValueChanged<ProjectMusic>? onMusicSelected;
  final String? selectedMusicId;
  final Duration playhead;
  final ValueChanged<Duration> onPlayheadChanged;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  final ValueChanged<TextOverlay> onOverlayChanged;
  final ValueChanged<TextOverlay>? onOverlaySelected;
  final ValueChanged<ClipSegment>? onSegmentSelected;
  final ValueChanged<ClipSegment>? onSegmentChanged;
  final String? selectedOverlayId;
  final String? selectedSegmentId;
  final bool isPlaying;
  final VoidCallback? onTogglePlay;

  /// Vertical drags on the transport row, so it doubles as a grab handle for
  /// collapsing the editor chrome.
  final GestureDragUpdateCallback? onHandleDragUpdate;
  final GestureDragEndCallback? onHandleDragEnd;
  final List<TimelineFilmstripFrame> filmstripFrames;

  /// Peak bars for the source video's embedded audio (full file).
  final List<double> sourceAudioWaveform;
  final bool hasSourceAudio;

  @override
  TimelineWidgetState createState() => TimelineWidgetState();
}

class TimelineWidgetState extends State<TimelineWidget> {
  double _zoom = 1.0;
  double _viewportWidth = 1;
  double _lanesScrollY = 0;

  /// Snapshot from the last frame — [oldWidget.overlays] is unsafe because the
  /// project mutates the same [List] in place before [didUpdateWidget] runs.
  int _knownOverlayCount = 0;
  String? _knownSelectedOverlayId;

  TimelineDragTarget _dragTarget = TimelineDragTarget.panTimeline;
  TextOverlay? _dragOverlay;
  ClipSegment? _tapSegment;
  Duration? _overlayAnchorStart;
  Duration? _overlayAnchorEnd;
  Duration? _overlayAnchorExportStart;
  Duration? _overlayAnchorExportEnd;
  bool _overlayDragOnBar = false;
  Duration? _musicAnchorStart;
  Duration? _musicAnchorSpan;
  double? _musicAnchorVolume;
  ProjectMusic? _dragMusic;
  ClipSegment? _dragSegment;
  double? _videoAudioAnchorVolume;

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

  @override
  void initState() {
    super.initState();
    _knownOverlayCount = widget.overlays.length;
    _knownSelectedOverlayId = widget.selectedOverlayId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      revealSelectedOverlay();
    });
  }

  /// Scrolls the music+text stack so [selectedOverlayId] is fully on-screen.
  void revealSelectedOverlay() {
    if (!mounted) return;
    final before = _lanesScrollY;
    _applyRevealContentRange(
      top: _textLaneContentTop(_laneIndexOf(widget.selectedOverlayId)),
      height: _laneHeight,
    );
    if (_lanesScrollY != before) {
      setState(() {});
    }
  }

  /// Scrolls so the selected music clip's lane is visible.
  void revealSelectedMusic() {
    if (!mounted) return;
    final music = _musicById(widget.selectedMusicId);
    if (music == null) return;
    final before = _lanesScrollY;
    _applyRevealContentRange(
      top: _musicLaneContentTop(music.lane),
      height: _musicTrackHeight,
    );
    if (_lanesScrollY != before) {
      setState(() {});
    }
  }

  /// Music lanes occupy the top of the scrollable stack (may be 0).
  double get _musicContentHeight {
    if (widget.musicTracks.isEmpty) return 0.0;
    return musicLaneCount(widget.musicTracks) * _musicLaneStride;
  }

  /// Top of the scrollable music+text region (video stays above).
  double get _scrollRegionTop => _videoTrackHeight;

  double get _textContentHeight =>
      (widget.overlays.isEmpty ? 1 : overlayLaneCount(widget.overlays)) *
      _laneStride;

  /// Full scrollable content: music lanes, then text lanes.
  double get _lanesContentHeight => _musicContentHeight + _textContentHeight;

  /// Viewport budget ≈ one music lane (when present) + up to 3 text lanes.
  double get _maxScrollViewportHeight {
    final musicReserve =
        widget.musicTracks.isEmpty ? 0.0 : _musicLaneStride;
    return musicReserve + _maxVisibleLanes * _laneStride;
  }

  double get _lanesViewportHeight =>
      _lanesContentHeight.clamp(0.0, _maxScrollViewportHeight);

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

  /// Scrolls so [top, top+height] in scroll-content space is fully visible.
  void _applyRevealContentRange({
    required double top,
    required double height,
  }) {
    if (top < 0 || height <= 0) return;
    final bottom = top + height;
    final viewport = _lanesViewportHeight;
    if (viewport <= 0) return;

    var next = _lanesScrollY;
    if (top < next) {
      next = top;
    } else if (bottom > next + viewport) {
      next = bottom - viewport;
    }
    _lanesScrollY = next.clamp(0.0, _maxLanesScroll);
  }

  double _musicLaneContentTop(int lane) => lane * _musicLaneStride;

  double _textLaneContentTop(int lane) {
    if (lane < 0) return -1;
    return _musicContentHeight + lane * _laneStride;
  }

  /// Viewport Y of a music lane (accounts for vertical scroll).
  double _musicLaneTop(int lane) =>
      _scrollRegionTop + _musicLaneContentTop(lane) - _lanesScrollY;

  double _musicLaneBottom(int lane) => _musicLaneTop(lane) + _musicTrackHeight;

  /// Y in the music+text scroll content for a viewport point.
  double _scrollContentY(Offset local) =>
      local.dy - _scrollRegionTop + _lanesScrollY;

  /// Text lane under the finger; allows one empty lane past the current max.
  int _textLaneAtLocal(Offset local, {int? currentLane}) {
    final textY = _scrollContentY(local) - _musicContentHeight;
    final raw = (textY / _laneStride).floor();
    final occupied = overlayLaneCount(widget.overlays);
    final limit = math.max(occupied, (currentLane ?? 0) + 1);
    if (raw < 0) return 0;
    if (raw > limit) return limit;
    return raw;
  }

  /// Music lane under the finger; allows one empty lane past the current max.
  int _musicLaneAtLocal(Offset local, {int? currentLane}) {
    final contentY = _scrollContentY(local);
    final raw = (contentY / _musicLaneStride).floor();
    final occupied = musicLaneCount(widget.musicTracks);
    final limit = math.max(occupied, (currentLane ?? 0) + 1);
    if (raw < 0) return 0;
    if (raw > limit) return limit;
    return raw;
  }

  int _laneIndexOf(String? overlayId) {
    if (overlayId == null) return -1;
    for (final overlay in widget.overlays) {
      if (overlay.id == overlayId) return overlay.lane;
    }
    return -1;
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

  /// Hit-tests the text bar under [local]. Empty lane space does not count —
  /// that gesture is for panning / scrolling the timeline.
  ///
  /// Unselected clips only hit on the bar body (not outward caps), so a
  /// neighbor's outside handle cannot steal focus from the selected clip.
  TextOverlay? _overlayInLaneAt(Offset local) {
    if (local.dy < _scrollRegionTop) return null;
    final textY = _scrollContentY(local) - _musicContentHeight;
    if (textY < -_overlayHandleOutsetY) return null;
    final x = local.dx.clamp(0.0, _viewportWidth);
    final point = Offset(x, textY);

    // Selected caps first (they extend outside the time span).
    final focused = _overlayById(widget.selectedOverlayId);
    if (focused != null) {
      final span = overlayTimelineSpan(focused, widget.segments);
      if (span != null) {
        final startX = _viewportXForSequence(span.start);
        final endX = _viewportXForSequence(span.end);
        final laneTop = focused.lane * _laneStride.toDouble();
        final laneBottom = laneTop + _laneHeight;
        final startHandle = overlayEdgeHandleRect(
          startX,
          top: laneTop,
          bottom: laneBottom,
          atStart: true,
        );
        final endHandle = overlayEdgeHandleRect(
          endX,
          top: laneTop,
          bottom: laneBottom,
          atStart: false,
        );
        if (startHandle.contains(point) ||
            endHandle.contains(point) ||
            (x >= startX && x <= endX)) {
          return focused;
        }
      }
    }

    final lane = textY ~/ _laneStride;
    final laneCount = overlayLaneCount(widget.overlays);
    if (lane < 0 || lane >= laneCount) return null;

    for (final overlay in widget.overlays) {
      if (overlay.lane != lane) continue;
      if (overlay.id == widget.selectedOverlayId) continue;
      final span = overlayTimelineSpan(overlay, widget.segments);
      if (span == null) continue;
      final startX = _viewportXForSequence(span.start);
      final endX = _viewportXForSequence(span.end);
      // Body only — outward caps of unfocused clips are ignored.
      if (x >= startX && x <= endX) return overlay;
    }
    return null;
  }

  TextOverlay? _overlayById(String? id) {
    if (id == null) return null;
    for (final overlay in widget.overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  ProjectMusic? _musicById(String? id) {
    if (id == null) return null;
    for (final music in widget.musicTracks) {
      if (music.id == id) return music;
    }
    return null;
  }

  /// Returns a drag target when [local] is on [overlay]; otherwise null.
  TimelineDragTarget? _overlayDragTargetFor(
    TextOverlay overlay,
    Offset local,
    double x,
  ) {
    final textY = _scrollContentY(local) - _musicContentHeight;
    if (textY < -_overlayHandleOutsetY) return null;

    final span = overlayTimelineSpan(overlay, widget.segments);
    if (span == null) return null;

    final startX = _viewportXForSequence(span.start);
    final endX = _viewportXForSequence(span.end);
    final laneTop = overlay.lane * _laneStride.toDouble();
    final laneBottom = laneTop + _laneHeight;
    final point = Offset(x, textY);
    final selected = overlay.id == widget.selectedOverlayId;

    final startHandle = overlayEdgeHandleRect(
      startX,
      top: laneTop,
      bottom: laneBottom,
      atStart: true,
    );
    final endHandle = overlayEdgeHandleRect(
      endX,
      top: laneTop,
      bottom: laneBottom,
      atStart: false,
    );

    if (selected) {
      final onStart = startHandle.contains(point);
      final onEnd = endHandle.contains(point);
      if (!onStart && !onEnd && (x < startX || x > endX)) return null;

      _dragOverlay = overlay;
      _overlayAnchorStart = overlay.start;
      _overlayAnchorEnd = overlay.end;
      _overlayAnchorExportStart = span.start;
      _overlayAnchorExportEnd = span.end;
      _overlayDragOnBar = true;

      if (onStart && (!onEnd || (x - startX).abs() <= (x - endX).abs())) {
        return TimelineDragTarget.overlayStart;
      }
      if (onEnd) return TimelineDragTarget.overlayEnd;
      if (x >= startX && x <= endX) return TimelineDragTarget.overlayMove;
      return null;
    }

    // Unfocused: body only (no outward-cap steal).
    if (x < startX || x > endX) return null;
    _dragOverlay = overlay;
    _overlayAnchorStart = overlay.start;
    _overlayAnchorEnd = overlay.end;
    _overlayAnchorExportStart = span.start;
    _overlayAnchorExportEnd = span.end;
    _overlayDragOnBar = true;
    return TimelineDragTarget.panTimeline;
  }

  bool _musicHandleContains(
    ProjectMusic music,
    double x,
    double y, {
    required bool atStart,
  }) {
    final seq = musicSequenceSpan(music, widget.segments);
    if (seq == null) return false;
    final edgeX =
        _viewportXForSequence(atStart ? seq.start : seq.end);
    final top = _musicLaneTop(music.lane);
    final bottom = _musicLaneBottom(music.lane);
    return overlayEdgeHandleRect(
      edgeX,
      top: top,
      bottom: bottom,
      atStart: atStart,
    ).contains(Offset(x, y));
  }

  /// Focused music grab — null when the point is not on this clip/chrome.
  TimelineDragTarget? _focusedMusicDragTarget(
    ProjectMusic music, {
    required double x,
    required double y,
  }) {
    final seq = musicSequenceSpan(music, widget.segments);
    if (seq == null) return null;
    final startX = _viewportXForSequence(seq.start);
    final endX = _viewportXForSequence(seq.end);
    final onHandle = _musicHandleContains(music, x, y, atStart: true) ||
        _musicHandleContains(music, x, y, atStart: false);
    final onBody = x >= startX && x <= endX;
    if (!onHandle && !onBody) {
      // Fade / volume knobs still live on the body.
      return null;
    }
    return _musicDragTargetFor(
      music,
      x: x,
      y: y,
      startX: startX,
      endX: endX,
    );
  }

  bool _isMusicBand(Offset local) {
    if (widget.musicTracks.isEmpty) return false;
    if (local.dy < _scrollRegionTop || local.dy >= _bodyHeight) return false;
    final contentY = _scrollContentY(local);
    return contentY >= 0 && contentY < _musicContentHeight;
  }

  ProjectMusic? _musicAtLocal(Offset local) {
    if (!_isMusicBand(local)) return null;
    final x = local.dx.clamp(0.0, _viewportWidth);
    final contentY = _scrollContentY(local);
    final lane = (contentY / _musicLaneStride).floor();

    ProjectMusic? hit;
    for (final music in widget.musicTracks) {
      if (music.lane != lane) continue;
      final seq = musicSequenceSpan(music, widget.segments);
      if (seq == null) continue;
      final startX = _viewportXForSequence(seq.start);
      final endX = _viewportXForSequence(seq.end);
      if (x >= startX && x <= endX) hit = music;
    }
    if (hit != null) return hit;

    // Empty spot on a lane: still allow selecting nearest clip on that lane.
    for (final music in widget.musicTracks.reversed) {
      if (music.lane != lane) continue;
      return music;
    }
    return null;
  }

  bool _isOverlayDragTarget(TimelineDragTarget target) {
    return target == TimelineDragTarget.overlayMove ||
        target == TimelineDragTarget.overlayStart ||
        target == TimelineDragTarget.overlayEnd;
  }

  bool _isMusicDragTarget(TimelineDragTarget target) {
    return target == TimelineDragTarget.musicMove ||
        target == TimelineDragTarget.musicStart ||
        target == TimelineDragTarget.musicEnd ||
        target == TimelineDragTarget.musicVolume ||
        target == TimelineDragTarget.musicFadeIn ||
        target == TimelineDragTarget.musicFadeOut;
  }

  bool _isVideoAudioDragTarget(TimelineDragTarget target) {
    return target == TimelineDragTarget.videoAudioVolume ||
        target == TimelineDragTarget.videoAudioFadeIn ||
        target == TimelineDragTarget.videoAudioFadeOut;
  }

  bool _isVideoAudioBand(Offset local) {
    if (!widget.hasSourceAudio) return false;
    return local.dy >= _videoFilmstripHeight && local.dy < _videoTrackHeight;
  }

  double _videoAudioBandTop() => _videoFilmstripHeight;
  double _videoAudioBandBottom() => _videoTrackHeight;

  double _videoVolumeLineY(ClipSegment segment) {
    final top = _videoAudioBandTop();
    final bottom = _videoAudioBandBottom();
    const pad = 4.0;
    final usable = (bottom - top - pad * 2).clamp(1.0, double.infinity);
    return bottom - pad - segment.volume.clamp(0.0, 1.0) * usable;
  }

  Offset _videoFadeInHandle(ClipSegment segment, double left, double right) {
    final xs = audioFadeHandleXs(
      left: left,
      right: right,
      fadeIn: segment.effectiveFadeIn,
      fadeOut: segment.effectiveFadeOut,
      duration: segment.duration,
    );
    return Offset(xs.inX, _videoVolumeLineY(segment));
  }

  Offset _videoFadeOutHandle(ClipSegment segment, double left, double right) {
    final xs = audioFadeHandleXs(
      left: left,
      right: right,
      fadeIn: segment.effectiveFadeIn,
      fadeOut: segment.effectiveFadeOut,
      duration: segment.duration,
    );
    return Offset(xs.outX, _videoVolumeLineY(segment));
  }

  TimelineDragTarget? _videoAudioDragTargetFor(
    ClipSegment segment, {
    required double x,
    required double y,
    required double startX,
    required double endX,
  }) {
    if (segment.id != widget.selectedSegmentId) return null;
    final width = endX - startX;
    if (width < _minAudioFadeBarWidth) return null;

    final fadeInPt = _videoFadeInHandle(segment, startX, endX);
    final fadeOutPt = _videoFadeOutHandle(segment, startX, endX);
    final dIn = (Offset(x, y) - fadeInPt).distance;
    final dOut = (Offset(x, y) - fadeOutPt).distance;
    if (dIn <= _musicFadeHitSlop && dIn <= dOut) {
      return TimelineDragTarget.videoAudioFadeIn;
    }
    if (dOut <= _musicFadeHitSlop) {
      return TimelineDragTarget.videoAudioFadeOut;
    }

    final volumeY = _videoVolumeLineY(segment);
    final inset = audioFadeHandleInset(width);
    final inFlat = x > startX + inset && x < endX - inset;
    if (inFlat && (y - volumeY).abs() <= _musicVolumeHitSlop) {
      return TimelineDragTarget.videoAudioVolume;
    }
    return null;
  }

  /// Same left/right as the painted audio bar (includes split gaps).
  ({double left, double right})? _segmentAudioBounds(ClipSegment target) {
    var sequenceOffset = Duration.zero;
    for (var i = 0; i < widget.segments.length; i++) {
      final segment = widget.segments[i];
      if (segment.id == target.id) {
        final rawLeft = _viewportXForSequence(sequenceOffset);
        final rawRight =
            _viewportXForSequence(sequenceOffset + segment.duration);
        return segmentBlockBounds(
          rawLeft: rawLeft,
          rawRight: rawRight,
          gapBefore: i > 0,
          gapAfter: i < widget.segments.length - 1,
        );
      }
      sequenceOffset += segment.duration;
    }
    return null;
  }

  double _volumeLineY(ProjectMusic music) {
    final top = _musicLaneTop(music.lane);
    final bottom = _musicLaneBottom(music.lane);
    const pad = 4.0;
    final usable = (bottom - top - pad * 2).clamp(1.0, double.infinity);
    return bottom - pad - music.volume.clamp(0.0, 1.0) * usable;
  }

  Offset _fadeInHandle(ProjectMusic music, double left, double right) {
    final spanMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
    final fadeMs = music.effectiveFadeIn.inMilliseconds;
    var x = left + (right - left) * (fadeMs / spanMs);
    final outX = _fadeOutHandleX(music, left, right);
    final minX = left + _musicFadeHandleInset;
    final maxX = outX - 8;
    if (maxX > minX) {
      x = x.clamp(minX, maxX);
    } else {
      x = minX;
    }
    return Offset(x, _volumeLineY(music));
  }

  Offset _fadeOutHandle(ProjectMusic music, double left, double right) {
    var x = _fadeOutHandleX(music, left, right);
    final inX = left +
        (right - left) *
            (music.effectiveFadeIn.inMilliseconds /
                music.clipDuration.inMilliseconds.clamp(1, 1 << 31));
    final maxX = right - _musicFadeHandleInset;
    final minX = math.max(left + _musicFadeHandleInset, inX + 8);
    if (maxX > minX) {
      x = x.clamp(minX, maxX);
    } else {
      x = maxX;
    }
    return Offset(x, _volumeLineY(music));
  }

  double _fadeOutHandleX(ProjectMusic music, double left, double right) {
    final spanMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
    final fadeMs = music.effectiveFadeOut.inMilliseconds;
    return right - (right - left) * (fadeMs / spanMs);
  }

  TimelineDragTarget _musicDragTargetFor(
    ProjectMusic music, {
    required double x,
    required double y,
    required double startX,
    required double endX,
  }) {
    final selected = music.id == widget.selectedMusicId;
    final width = endX - startX;

    if (selected && width > _musicFadeHandleInset * 2 + 8) {
      final fadeInPt = _fadeInHandle(music, startX, endX);
      final fadeOutPt = _fadeOutHandle(music, startX, endX);
      final dIn = (Offset(x, y) - fadeInPt).distance;
      final dOut = (Offset(x, y) - fadeOutPt).distance;
      // Fade handles win over trim so they are not stolen by edge grabs.
      if (dIn <= _musicFadeHitSlop && dIn <= dOut) {
        return TimelineDragTarget.musicFadeIn;
      }
      if (dOut <= _musicFadeHitSlop) {
        return TimelineDragTarget.musicFadeOut;
      }

      final volumeY = _volumeLineY(music);
      final inFlatZone =
          x > startX + _musicFadeHandleInset &&
          x < endX - _musicFadeHandleInset;
      if (inFlatZone && (y - volumeY).abs() <= _musicVolumeHitSlop) {
        return TimelineDragTarget.musicVolume;
      }
    }

    // Inward white trim bars (same rect as paint).
    final laneTop = _musicLaneTop(music.lane);
    final laneBottom = _musicLaneBottom(music.lane);
    final point = Offset(x, y);
    final startHandle = overlayEdgeHandleRect(
      startX,
      top: laneTop,
      bottom: laneBottom,
      atStart: true,
    );
    final endHandle = overlayEdgeHandleRect(
      endX,
      top: laneTop,
      bottom: laneBottom,
      atStart: false,
    );
    final onStart = startHandle.contains(point);
    final onEnd = endHandle.contains(point);
    if (onStart && (!onEnd || (x - startX).abs() <= (x - endX).abs())) {
      return TimelineDragTarget.musicStart;
    }
    if (onEnd) {
      return TimelineDragTarget.musicEnd;
    }

    if (x >= startX && x <= endX) return TimelineDragTarget.musicMove;
    return TimelineDragTarget.musicMove;
  }

  TimelineDragTarget _hitTest(Offset local) {
    final x = local.dx.clamp(0.0, _viewportWidth);

    // No playhead target: it is fixed at the centre, so grabbing it would be
    // indistinguishable from panning the strip underneath it.

    _dragOverlay = null;
    _dragMusic = null;
    _tapSegment = null;
    _overlayAnchorExportStart = null;
    _overlayAnchorExportEnd = null;
    _overlayDragOnBar = false;
    _musicAnchorStart = null;
    _musicAnchorSpan = null;
    _musicAnchorVolume = null;

    // Focused clip wins first: its outside end-caps sit over the next clip's
    // body, so a generic lane pick would steal the grab and change selection.
    final focusedOverlay = _overlayById(widget.selectedOverlayId);
    if (focusedOverlay != null) {
      final target = _overlayDragTargetFor(focusedOverlay, local, x);
      if (target != null) return target;
    }

    final overlay = _overlayInLaneAt(local);
    if (overlay != null && overlay.id != widget.selectedOverlayId) {
      final target = _overlayDragTargetFor(overlay, local, x);
      if (target != null) return target;
    }

    if (_isMusicBand(local)) {
      final focusedMusic = _musicById(widget.selectedMusicId);
      if (focusedMusic != null) {
        final target = _focusedMusicDragTarget(focusedMusic, x: x, y: local.dy);
        if (target != null) {
          _dragMusic = focusedMusic;
          _musicAnchorStart = focusedMusic.timelineStart;
          _musicAnchorSpan = focusedMusic.clipDuration;
          _musicAnchorVolume = focusedMusic.volume;
          return target;
        }
      }

      final music = _musicAtLocal(local);
      if (music != null && music.id != widget.selectedMusicId) {
        _dragMusic = music;
        _musicAnchorStart = music.timelineStart;
        _musicAnchorSpan = music.clipDuration;
        _musicAnchorVolume = music.volume;
        // Unfocused music: tap to select only; drag pans the timeline.
        return TimelineDragTarget.panTimeline;
      }
    }

    // Clip track: source-audio envelope, trim handles, then segment selection.
    if (local.dy < _videoTrackHeight) {
      _dragSegment = null;
      _videoAudioAnchorVolume = null;

      if (_isVideoAudioBand(local)) {
        final segment = _segmentAtViewportX(x);
        if (segment != null) {
          _dragSegment = segment;
          _videoAudioAnchorVolume = segment.volume;
          _tapSegment = segment;
          final bounds = _segmentAudioBounds(segment);
          if (bounds != null) {
            final audioTarget = _videoAudioDragTargetFor(
              segment,
              x: x,
              y: local.dy,
              startX: bounds.left,
              endX: bounds.right,
            );
            if (audioTarget != null) return audioTarget;
          }
        }
      }

      final trimStartX = _viewportXForSequence(Duration.zero);
      final trimEndX = _viewportXForSequence(_sequenceDuration);
      final trimPoint = Offset(x, local.dy);
      final trimStartHandle = overlayEdgeHandleRect(
        trimStartX,
        top: 0,
        bottom: _videoTrackHeight,
        atStart: true,
      );
      final trimEndHandle = overlayEdgeHandleRect(
        trimEndX,
        top: 0,
        bottom: _videoTrackHeight,
        atStart: false,
      );
      if (trimStartHandle.contains(trimPoint)) {
        return TimelineDragTarget.trimStart;
      }
      if (trimEndHandle.contains(trimPoint)) {
        return TimelineDragTarget.trimEnd;
      }

      _tapSegment = _segmentAtViewportX(x);
    }

    return TimelineDragTarget.panTimeline;
  }

  Duration? _sequenceOffsetOfSegment(ClipSegment target) {
    var offset = Duration.zero;
    for (final segment in widget.segments) {
      if (segment.id == target.id) return offset;
      offset += segment.duration;
    }
    return null;
  }

  void _beginSingle(Offset local) {
    _didMove = false;
    _dragAxis = null;
    _selectionAnnounced = false;
    _pointerDownLocal = local;
    _lastSingleLocal = local;
    _panAnchorSequenceTime = null;
    _dragTarget = _hitTest(local);
    if ((_isOverlayDragTarget(_dragTarget) && _overlayDragOnBar) ||
        _isMusicDragTarget(_dragTarget) ||
        _isVideoAudioDragTarget(_dragTarget)) {
      _dragAxis = Axis.horizontal;
    } else if (_dragTarget == TimelineDragTarget.panTimeline) {
      _panAnchorSequenceTime = _sequenceTimeAtViewportX(_viewportWidth / 2);
    }
  }

  /// Vertical wins only when there is something to scroll, so the gesture is
  /// never swallowed by a lane area that cannot move.
  ///
  /// This applies to layer bars too: with lanes packed edge to edge there is
  /// no empty strip left to start a scroll from.
  Axis? _resolveDragAxis(Offset local) {
    if (_isOverlayDragTarget(_dragTarget) && _overlayDragOnBar) {
      return Axis.horizontal;
    }

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
        final minStart = _overlayTrimMinStart(overlay);
        final maxStart = overlay.end - minOverlayDuration;
        widget.onOverlayChanged(
          overlay.copyWith(
            start: clampDuration(t, minStart, maxStart),
          ),
        );
      case TimelineDragTarget.overlayEnd:
        final overlay = _dragOverlay;
        if (overlay == null) return;
        final t = _timeAtViewportX(x);
        final minEnd = overlay.start + minOverlayDuration;
        final maxEnd = _overlayTrimMaxEnd(overlay);
        widget.onOverlayChanged(
          overlay.copyWith(
            end: clampDuration(t, minEnd, maxEnd),
          ),
        );
      case TimelineDragTarget.overlayMove:
        final overlay = _dragOverlay;
        final anchorStart = _overlayAnchorStart;
        final anchorEnd = _overlayAnchorEnd;
        final exportStart = _overlayAnchorExportStart;
        final exportEnd = _overlayAnchorExportEnd;
        final downLocal = _pointerDownLocal;
        if (overlay == null ||
            anchorStart == null ||
            anchorEnd == null ||
            exportStart == null ||
            exportEnd == null ||
            downLocal == null) {
          return;
        }

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
        final targetLane = _textLaneAtLocal(local, currentLane: overlay.lane);
        widget.onOverlayChanged(
          overlay.copyWith(
            start: nextStart,
            end: nextEnd,
            lane: targetLane,
          ),
        );
      case TimelineDragTarget.musicMove:
        final music = _dragMusic;
        final anchorStart = _musicAnchorStart;
        final anchorSpan = _musicAnchorSpan;
        final downLocal = _pointerDownLocal;
        if (music == null ||
            anchorStart == null ||
            anchorSpan == null ||
            downLocal == null) {
          return;
        }
        final msPerPx = _sequenceDuration.inMilliseconds / _contentWidth;
        final totalDeltaMs = ((x - downLocal.dx) * msPerPx).round();
        var nextStart = Duration(
          milliseconds: anchorStart.inMilliseconds + totalDeltaMs,
        );
        if (nextStart < Duration.zero) nextStart = Duration.zero;
        final maxStart = widget.duration - anchorSpan;
        if (nextStart > maxStart) {
          nextStart = maxStart.isNegative ? Duration.zero : maxStart;
        }
        final targetLane = _musicLaneAtLocal(local, currentLane: music.lane);
        widget.onMusicChanged?.call(
          music.copyWith(timelineStart: nextStart, lane: targetLane),
        );
      case TimelineDragTarget.musicEnd:
        final music = _liveMusic(_dragMusic) ?? _dragMusic;
        if (music == null) return;
        final t = _timeAtViewportX(x);
        final minEnd = music.timelineStart + minMusicClipDuration;
        // iMovie-style: extend reveals more of the file at 1x. Never past EOF.
        // Until fileDuration is known, only allow shortening (not extending).
        final maxFromFile = music.fileDuration == null
            ? music.timelineEnd
            : music.timelineStart +
                (music.fileDuration! - music.sourceOffset);
        final neighborWall = _musicTrimMaxEnd(music);
        var nextEnd = clampDuration(t, minEnd, widget.duration);
        if (nextEnd > maxFromFile) nextEnd = maxFromFile;
        if (nextEnd > neighborWall) nextEnd = neighborWall;
        final nextClip = nextEnd - music.timelineStart;
        if (nextClip < minMusicClipDuration) return;
        if (music.fileDuration != null) {
          final maxClip = music.fileDuration! - music.sourceOffset;
          if (nextClip > maxClip) return;
        }
        widget.onMusicChanged?.call(music.copyWith(clipDuration: nextClip));
      case TimelineDragTarget.musicStart:
        final music = _liveMusic(_dragMusic) ?? _dragMusic;
        if (music == null) return;
        final t = _timeAtViewportX(x);
        final neighborWall = _musicTrimMinStart(music);
        var nextStart = clampDuration(
          t,
          neighborWall,
          music.timelineEnd - minMusicClipDuration,
        );
        final delta = nextStart - music.timelineStart;
        final nextOffset = music.sourceOffset + delta;
        if (nextOffset.isNegative) return;
        if (music.fileDuration != null &&
            nextOffset >= music.fileDuration!) {
          return;
        }
        final nextClip = music.clipDuration - delta;
        if (nextClip < minMusicClipDuration) return;
        if (music.fileDuration != null &&
            nextOffset + nextClip > music.fileDuration!) {
          return;
        }
        widget.onMusicChanged?.call(
          music.copyWith(
            timelineStart: nextStart,
            sourceOffset: nextOffset,
            clipDuration: nextClip,
          ),
        );
      case TimelineDragTarget.musicVolume:
        final music = _liveMusic(_dragMusic);
        final downLocal = _pointerDownLocal;
        final anchorVolume = _musicAnchorVolume;
        if (music == null || downLocal == null || anchorVolume == null) return;
        final usable = (_musicTrackHeight - 8).clamp(1.0, double.infinity);
        // Drag up → louder.
        final next = (anchorVolume - (local.dy - downLocal.dy) / usable)
            .clamp(0.0, 1.0);
        widget.onMusicChanged?.call(music.copyWith(volume: next));
      case TimelineDragTarget.musicFadeIn:
        final music = _liveMusic(_dragMusic);
        if (music == null) return;
        final t = _timeAtViewportX(x);
        final fade = clampDuration(
          t - music.timelineStart,
          Duration.zero,
          music.maxFadeIn,
        );
        widget.onMusicChanged?.call(music.copyWith(fadeIn: fade));
      case TimelineDragTarget.musicFadeOut:
        final music = _liveMusic(_dragMusic);
        if (music == null) return;
        final t = _timeAtViewportX(x);
        final fromEnd = music.timelineEnd - t;
        final fade = clampDuration(fromEnd, Duration.zero, music.maxFadeOut);
        widget.onMusicChanged?.call(music.copyWith(fadeOut: fade));
      case TimelineDragTarget.videoAudioVolume:
        final segment = _liveSegment(_dragSegment);
        final downLocal = _pointerDownLocal;
        final anchorVolume = _videoAudioAnchorVolume;
        if (segment == null || downLocal == null || anchorVolume == null) {
          return;
        }
        final usable = (_videoAudioHeight - 8).clamp(1.0, double.infinity);
        final next = (anchorVolume - (local.dy - downLocal.dy) / usable)
            .clamp(0.0, 1.0);
        widget.onSegmentChanged?.call(segment.copyWith(volume: next));
      case TimelineDragTarget.videoAudioFadeIn:
        final segment = _liveSegment(_dragSegment);
        if (segment == null) return;
        final seqStart = _sequenceOffsetOfSegment(segment);
        if (seqStart == null) return;
        final t = _timeAtViewportX(x);
        final localT = t - seqStart;
        final fade = clampDuration(localT, Duration.zero, segment.maxFadeIn);
        widget.onSegmentChanged?.call(segment.copyWith(fadeIn: fade));
      case TimelineDragTarget.videoAudioFadeOut:
        final segment = _liveSegment(_dragSegment);
        if (segment == null) return;
        final seqStart = _sequenceOffsetOfSegment(segment);
        if (seqStart == null) return;
        final t = _timeAtViewportX(x);
        final fromEnd = (seqStart + segment.duration) - t;
        final fade = clampDuration(fromEnd, Duration.zero, segment.maxFadeOut);
        widget.onSegmentChanged?.call(segment.copyWith(fadeOut: fade));
    }
  }

  ProjectMusic? _liveMusic(ProjectMusic? fallback) {
    if (fallback == null) return null;
    for (final music in widget.musicTracks) {
      if (music.id == fallback.id) return music;
    }
    return fallback;
  }

  ClipSegment? _liveSegment(ClipSegment? fallback) {
    if (fallback == null) return null;
    for (final segment in widget.segments) {
      if (segment.id == fallback.id) return segment;
    }
    return fallback;
  }

  /// Same-lane clip that starts at/after [clip] — blocks extending the end.
  Duration _overlayTrimMaxEnd(TextOverlay clip) {
    var maxEnd = widget.duration;
    for (final other in widget.overlays) {
      if (other.id == clip.id || other.lane != clip.lane) continue;
      if (other.start >= clip.start && other.start < maxEnd) {
        maxEnd = other.start;
      }
    }
    return maxEnd;
  }

  /// Same-lane clip that ends at/before [clip] — blocks pulling the start left.
  Duration _overlayTrimMinStart(TextOverlay clip) {
    var minStart = Duration.zero;
    for (final other in widget.overlays) {
      if (other.id == clip.id || other.lane != clip.lane) continue;
      if (other.start < clip.start &&
          other.end <= clip.end &&
          other.end > minStart) {
        minStart = other.end;
      }
    }
    return minStart;
  }

  Duration _musicTrimMaxEnd(ProjectMusic clip) {
    var maxEnd = widget.duration;
    for (final other in widget.musicTracks) {
      if (other.id == clip.id || other.lane != clip.lane) continue;
      if (other.timelineStart >= clip.timelineStart &&
          other.timelineStart < maxEnd) {
        maxEnd = other.timelineStart;
      }
    }
    return maxEnd;
  }

  Duration _musicTrimMinStart(ProjectMusic clip) {
    var minStart = Duration.zero;
    for (final other in widget.musicTracks) {
      if (other.id == clip.id || other.lane != clip.lane) continue;
      if (other.timelineStart < clip.timelineStart &&
          other.timelineEnd <= clip.timelineEnd &&
          other.timelineEnd > minStart) {
        minStart = other.timelineEnd;
      }
    }
    return minStart;
  }

  void _announceSelection() {
    final overlay = _dragOverlay;
    if (overlay != null && !_selectionAnnounced) {
      _selectionAnnounced = true;
      widget.onOverlaySelected?.call(overlay);
      return;
    }
    final music = _dragMusic;
    if (music != null && !_selectionAnnounced) {
      _selectionAnnounced = true;
      widget.onMusicSelected?.call(music);
      return;
    }
    final segment = _dragSegment ?? _tapSegment;
    if (segment != null &&
        _isVideoAudioDragTarget(_dragTarget) &&
        !_selectionAnnounced) {
      _selectionAnnounced = true;
      widget.onSegmentSelected?.call(segment);
    }
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

    if (tapped && _dragOverlay != null && _overlayDragOnBar) {
      _announceSelection();
    } else if (tapped && _dragMusic != null) {
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
    _dragMusic = null;
    _dragSegment = null;
    _tapSegment = null;
    _overlayAnchorStart = null;
    _overlayAnchorEnd = null;
    _overlayAnchorExportStart = null;
    _overlayAnchorExportEnd = null;
    _overlayDragOnBar = false;
    _musicAnchorStart = null;
    _musicAnchorSpan = null;
    _musicAnchorVolume = null;
    _videoAudioAnchorVolume = null;
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

    // Do not use oldWidget.overlays.length — the list is mutated in place.
    final gainedLayer = widget.overlays.length > _knownOverlayCount;
    final selectionMoved =
        widget.selectedOverlayId != _knownSelectedOverlayId;
    _knownOverlayCount = widget.overlays.length;
    _knownSelectedOverlayId = widget.selectedOverlayId;

    if (gainedLayer || selectionMoved) {
      // Sync before this build so the bar can paint on-screen immediately.
      _applyRevealContentRange(
        top: _textLaneContentTop(_laneIndexOf(widget.selectedOverlayId)),
        height: _laneHeight,
      );
      // Viewport height may change when a 4th+ lane appears.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        revealSelectedOverlay();
      });
    }

    if (widget.selectedMusicId != oldWidget.selectedMusicId &&
        widget.selectedMusicId != null) {
      revealSelectedMusic();
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
                        musicTracks: widget.musicTracks,
                        musicWaveforms: widget.musicWaveforms,
                        sourceAudioWaveform: widget.sourceAudioWaveform,
                        hasSourceAudio: widget.hasSourceAudio,
                        sourceDuration: widget.duration,
                        filmstripFrames: widget.filmstripFrames,
                        selectedOverlayId: widget.selectedOverlayId,
                        selectedSegmentId: widget.selectedSegmentId,
                        selectedMusicId: widget.selectedMusicId,
                        scrollPx: _scrollPx,
                        contentWidth: _contentWidth,
                        contentInsetX: _contentInsetX,
                        zoom: _zoom,
                        lanesScrollY: _lanesScrollY,
                        lanesContentHeight: _lanesContentHeight,
                        musicContentHeight: _musicContentHeight,
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
    required this.musicTracks,
    required this.musicWaveforms,
    required this.sourceAudioWaveform,
    required this.hasSourceAudio,
    required this.sourceDuration,
    required this.scrollPx,
    required this.contentWidth,
    required this.contentInsetX,
    required this.zoom,
    required this.lanesScrollY,
    required this.lanesContentHeight,
    required this.musicContentHeight,
    required this.laneLabelStyle,
    this.filmstripFrames = const [],
    this.selectedOverlayId,
    this.selectedSegmentId,
    this.selectedMusicId,
  });

  final Duration sequenceDuration;
  final Duration sequencePlayhead;
  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final List<ProjectMusic> musicTracks;
  final Map<String, List<double>> musicWaveforms;
  final List<double> sourceAudioWaveform;
  final bool hasSourceAudio;
  final Duration sourceDuration;
  final double scrollPx;
  final double contentWidth;
  final double contentInsetX;
  final double zoom;
  final double lanesScrollY;
  final double lanesContentHeight;
  final double musicContentHeight;
  final TextStyle laneLabelStyle;
  final List<TimelineFilmstripFrame> filmstripFrames;
  final String? selectedOverlayId;
  final String? selectedSegmentId;
  final String? selectedMusicId;

  double get _scrollRegionTop => _videoTrackHeight;

  double _x(Duration sequenceTime) {
    return durationToContentX(sequenceTime, sequenceDuration, contentWidth) -
        scrollPx +
        contentInsetX;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintClipTrack(canvas, size);
    _paintScrollTracks(canvas, size);
    _paintPlayhead(canvas, size);
  }

  void _paintScrollTracks(Canvas canvas, Size size) {
    final viewportHeight = size.height - _scrollRegionTop;
    if (viewportHeight <= 0) return;

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, _scrollRegionTop, size.width, viewportHeight),
    );
    canvas.translate(0, _scrollRegionTop - lanesScrollY);

    _paintMusicInScrollContent(canvas, size, viewportHeight);
    _paintTextInScrollContent(canvas, size, viewportHeight);

    canvas.restore();
    _paintLaneScrollbar(canvas, size, viewportHeight);
  }

  void _paintMusicInScrollContent(
    Canvas canvas,
    Size size,
    double viewportHeight,
  ) {
    if (musicTracks.isEmpty || musicContentHeight <= 0) return;

    final laneCount = musicLaneCount(musicTracks);
    for (var lane = 0; lane < laneCount; lane++) {
      final top = lane * _musicLaneStride;
      if (top - lanesScrollY > viewportHeight ||
          top - lanesScrollY + _musicTrackHeight < 0) {
        continue;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, top, size.width, top + _musicTrackHeight),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFF1A2330),
      );
    }

    for (final music in musicTracks) {
      if (music.id == selectedMusicId) continue;
      _paintMusicClip(canvas, size, music, selected: false);
    }
    for (final music in musicTracks) {
      if (music.id != selectedMusicId) continue;
      _paintMusicClip(canvas, size, music, selected: true);
    }
  }

  void _paintMusicClip(
    Canvas canvas,
    Size size,
    ProjectMusic music, {
    required bool selected,
  }) {
      final span = musicSequenceSpan(music, segments);
      if (span == null) return;
      final left = _x(span.start);
      final right = _x(span.end);
      if (right < 0 || left > size.width) return;

      final top = music.lane * _musicLaneStride;
      final bottom = top + _musicTrackHeight;
      final viewportHeight = size.height - _scrollRegionTop;
      if (top - lanesScrollY > viewportHeight ||
          bottom - lanesScrollY < 0) {
        return;
      }

      final rect = Rect.fromLTRB(left, top, right, bottom);
      final clipRRect = RRect.fromRectAndRadius(rect, const Radius.circular(4));

      canvas.save();
      canvas.clipRRect(clipRRect);

      canvas.drawRRect(
        clipRRect,
        Paint()
          ..color = selected
              ? const Color(0xFF3DDC97)
              : const Color(0xFF2A9D8F).withValues(alpha: 0.9),
      );

      final peaks = musicWaveforms[music.fileName] ?? const <double>[];
      _paintMusicWaveform(canvas, rect, music, peaks);

      final darkAbove = _musicDarkAbovePath(music, rect);
      canvas.drawPath(
        darkAbove,
        Paint()..color = Colors.black.withValues(alpha: 0.28),
      );

      canvas.drawPath(
        _musicEnvelopePath(music, rect),
        Paint()
          ..color = selected ? Colors.white : Colors.white.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1.6 : 1.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      _paintLaneLabel(canvas, rect, '♪ ${music.title}');
      canvas.restore();

      if (selected) {
        _drawHandle(
          canvas,
          left,
          top: top,
          bottom: bottom,
          color: Colors.white,
          atStart: true,
        );
        _drawHandle(
          canvas,
          right,
          top: top,
          bottom: bottom,
          color: Colors.white,
          atStart: false,
        );
        if (kDebugMode) {
          _paintDebugEdgeHitZone(
            canvas,
            left,
            top: top,
            bottom: bottom,
            atStart: true,
          );
          _paintDebugEdgeHitZone(
            canvas,
            right,
            top: top,
            bottom: bottom,
            atStart: false,
          );
        }
        _paintFadeHandle(
          canvas,
          _fadeHandleOffset(music, left, right, fadeIn: true),
        );
        _paintFadeHandle(
          canvas,
          _fadeHandleOffset(music, left, right, fadeIn: false),
        );
      }
  }

  Path _musicEnvelopePath(ProjectMusic music, Rect rect) {
    const pad = 4.0;
    final usable = (rect.height - pad * 2).clamp(1.0, double.infinity);
    final bottom = rect.bottom - pad;
    final path = Path();
    const samples = 64;
    final clipMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final local = Duration(milliseconds: (clipMs * t).round());
      final y = bottom - music.volumeAt(local) * usable;
      final x = rect.left + rect.width * t;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }

  /// Region above the volume envelope — shaded so the line reads clearly.
  Path _musicDarkAbovePath(ProjectMusic music, Rect rect) {
    const pad = 4.0;
    final usable = (rect.height - pad * 2).clamp(1.0, double.infinity);
    final bottom = rect.bottom - pad;
    const samples = 64;
    final clipMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
    final path = Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top);
    for (var i = samples; i >= 0; i--) {
      final t = i / samples;
      final local = Duration(milliseconds: (clipMs * t).round());
      final y = bottom - music.volumeAt(local) * usable;
      final x = rect.left + rect.width * t;
      path.lineTo(x, y);
    }
    path.close();
    return path;
  }

  Offset _fadeHandleOffset(
    ProjectMusic music,
    double left,
    double right, {
    required bool fadeIn,
  }) {
    if (fadeIn) {
      final spanMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
      final fadeMs = music.effectiveFadeIn.inMilliseconds;
      var x = left + (right - left) * (fadeMs / spanMs);
      final outFadeMs = music.effectiveFadeOut.inMilliseconds;
      final outX = right - (right - left) * (outFadeMs / spanMs);
      final minX = left + _musicFadeHandleInset;
      final maxX = outX - 8;
      if (maxX > minX) {
        x = x.clamp(minX, maxX);
      } else {
        x = minX;
      }
      const pad = 4.0;
      final usable = (_musicTrackHeight - pad * 2).clamp(1.0, double.infinity);
      final top = music.lane * _musicLaneStride;
      final bottom = top + _musicTrackHeight;
      final y = bottom - pad - music.volume.clamp(0.0, 1.0) * usable;
      return Offset(x, y);
    }

    final spanMs = music.clipDuration.inMilliseconds.clamp(1, 1 << 31);
    final fadeMs = music.effectiveFadeOut.inMilliseconds;
    var x = right - (right - left) * (fadeMs / spanMs);
    final inFadeMs = music.effectiveFadeIn.inMilliseconds;
    final inX = left + (right - left) * (inFadeMs / spanMs);
    final maxX = right - _musicFadeHandleInset;
    final minX = math.max(left + _musicFadeHandleInset, inX + 8);
    if (maxX > minX) {
      x = x.clamp(minX, maxX);
    } else {
      x = maxX;
    }
    const pad = 4.0;
    final usable = (_musicTrackHeight - pad * 2).clamp(1.0, double.infinity);
    final top = music.lane * _musicLaneStride;
    final bottom = top + _musicTrackHeight;
    final y = bottom - pad - music.volume.clamp(0.0, 1.0) * usable;
    return Offset(x, y);
  }

  void _paintFadeHandle(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      5.5,
      Paint()..color = const Color(0xFFFFCC66),
    );
    canvas.drawCircle(
      center,
      5.5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  void _paintMusicWaveform(
    Canvas canvas,
    Rect rect,
    ProjectMusic music,
    List<double> peaks,
  ) {
    if (peaks.isEmpty || rect.width < 4) return;

    // Map the visible source window onto the file. Without fileDuration the
    // same peaks would stretch when the clip grows — that looks like slow-mo.
    final fileMs = music.fileDuration?.inMilliseconds;
    if (fileMs == null || fileMs <= 0) return;

    final startF =
        (music.sourceOffset.inMilliseconds / fileMs).clamp(0.0, 1.0);
    final endF = ((music.sourceOffset + music.clipDuration).inMilliseconds /
            fileMs)
        .clamp(startF + 0.001, 1.0);

    final i0 = (startF * (peaks.length - 1)).floor().clamp(0, peaks.length - 1);
    final i1 = (endF * (peaks.length - 1))
        .ceil()
        .clamp(i0 + 1, peaks.length);
    final slice = peaks.sublist(i0, i1);
    if (slice.isEmpty) return;

    final mid = rect.center.dy;
    final half = rect.height * 0.4;
    final barW = rect.width / slice.length;
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.32);

    for (var i = 0; i < slice.length; i++) {
      final amp = slice[i].clamp(0.06, 1.0);
      final h = half * amp;
      final x = rect.left + i * barW;
      final w = math.max(1.0, barW * 0.72);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x + barW / 2, mid),
            width: w,
            height: h * 2,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  void _paintClipTrack(Canvas canvas, Size size) {
    if (segments.isEmpty) return;

    final filmTop = 2.0;
    final filmBottom = hasSourceAudio
        ? _videoFilmstripHeight - 1
        : _videoTrackHeight - 2.0;
    final audioTop = _videoFilmstripHeight;
    final audioBottom = _videoTrackHeight - 2.0;

    final envelopeLeft = _x(Duration.zero);
    final envelopeRight = _x(sequenceDuration);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(envelopeLeft, filmTop, envelopeRight, audioBottom),
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
      final filmRect =
          Rect.fromLTRB(bounds.left, filmTop, bounds.right, filmBottom);
      final filmRounded =
          RRect.fromRectAndRadius(filmRect, const Radius.circular(4));

      _paintFilmstrip(canvas, filmRect, segment);

      canvas.drawRRect(
        filmRounded,
        Paint()
          ..color = selected
              ? AppTheme.accent.withValues(alpha: 0.28)
              : Colors.black.withValues(alpha: 0.12),
      );

      if (hasSourceAudio) {
        final audioRect =
            Rect.fromLTRB(bounds.left, audioTop, bounds.right, audioBottom);
        _paintSourceAudioBand(canvas, audioRect, segment, selected: selected);
      }

      if (selected) {
        final fullRect =
            Rect.fromLTRB(bounds.left, filmTop, bounds.right, audioBottom);
        canvas.drawRRect(
          RRect.fromRectAndRadius(fullRect, const Radius.circular(4)),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }

      if (i < segments.length - 1) {
        final dividerX = rawRight;
        canvas.drawLine(
          Offset(dividerX, filmTop + 2),
          Offset(dividerX, audioBottom - 2),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.65)
            ..strokeWidth = 1.5,
        );
        if (segment.hasTransition) {
          final midY = (filmTop + audioBottom) / 2;
          final diamond = Path()
            ..moveTo(dividerX, midY - 5)
            ..lineTo(dividerX + 5, midY)
            ..lineTo(dividerX, midY + 5)
            ..lineTo(dividerX - 5, midY)
            ..close();
          canvas.drawPath(
            diamond,
            Paint()..color = const Color(0xFFFBBF24),
          );
          canvas.drawPath(
            diamond,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.55)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }

      sequenceOffset += segment.duration;
    }

    _drawHandle(
      canvas,
      _x(Duration.zero),
      top: filmTop,
      bottom: audioBottom,
      color: AppTheme.accent,
      atStart: true,
    );
    _drawHandle(
      canvas,
      _x(sequenceDuration),
      top: filmTop,
      bottom: audioBottom,
      color: AppTheme.accent,
      atStart: false,
    );
  }

  void _paintSourceAudioBand(
    Canvas canvas,
    Rect rect,
    ClipSegment segment, {
    required bool selected,
  }) {
    final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(
      rounded,
      Paint()..color = const Color(0xFF1B3A3A),
    );

    canvas.save();
    canvas.clipRRect(rounded);

    _paintSegmentWaveform(canvas, rect, segment);

    final darkAbove = _segmentDarkAbovePath(segment, rect);
    canvas.drawPath(
      darkAbove,
      Paint()..color = Colors.black.withValues(alpha: 0.3),
    );
    canvas.drawPath(
      _segmentEnvelopePath(segment, rect),
      Paint()
        ..color = selected ? Colors.white : Colors.white.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 1.5 : 1.1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();

    if (selected) {
      _paintFadeHandle(
        canvas,
        _segmentFadeHandleOffset(segment, rect.left, rect.right, fadeIn: true),
      );
      _paintFadeHandle(
        canvas,
        _segmentFadeHandleOffset(segment, rect.left, rect.right, fadeIn: false),
      );
    }
  }

  Path _segmentEnvelopePath(ClipSegment segment, Rect rect) {
    const pad = 3.0;
    final usable = (rect.height - pad * 2).clamp(1.0, double.infinity);
    final bottom = rect.bottom - pad;
    final path = Path();
    const samples = 48;
    final clipMs = segment.duration.inMilliseconds.clamp(1, 1 << 31);
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final local = Duration(milliseconds: (clipMs * t).round());
      final y = bottom - segment.volumeAt(local) * usable;
      final x = rect.left + rect.width * t;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }

  Path _segmentDarkAbovePath(ClipSegment segment, Rect rect) {
    const pad = 3.0;
    final usable = (rect.height - pad * 2).clamp(1.0, double.infinity);
    final bottom = rect.bottom - pad;
    const samples = 48;
    final clipMs = segment.duration.inMilliseconds.clamp(1, 1 << 31);
    final path = Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top);
    for (var i = samples; i >= 0; i--) {
      final t = i / samples;
      final local = Duration(milliseconds: (clipMs * t).round());
      final y = bottom - segment.volumeAt(local) * usable;
      final x = rect.left + rect.width * t;
      path.lineTo(x, y);
    }
    path.close();
    return path;
  }

  Offset _segmentFadeHandleOffset(
    ClipSegment segment,
    double left,
    double right, {
    required bool fadeIn,
  }) {
    final xs = audioFadeHandleXs(
      left: left,
      right: right,
      fadeIn: segment.effectiveFadeIn,
      fadeOut: segment.effectiveFadeOut,
      duration: segment.duration,
    );
    const pad = 3.0;
    final usable = (_videoAudioHeight - pad * 2).clamp(1.0, double.infinity);
    final top = _videoFilmstripHeight;
    final bottom = top + _videoAudioHeight;
    final y = bottom - pad - segment.volume.clamp(0.0, 1.0) * usable;
    return Offset(fadeIn ? xs.inX : xs.outX, y);
  }

  void _paintSegmentWaveform(
    Canvas canvas,
    Rect rect,
    ClipSegment segment,
  ) {
    if (sourceAudioWaveform.isEmpty || rect.width < 4) return;
    final totalMs = sourceDuration.inMilliseconds.clamp(1, 1 << 31);
    final startF = (segment.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final endF =
        (segment.end.inMilliseconds / totalMs).clamp(startF + 0.001, 1.0);

    final i0 = (startF * (sourceAudioWaveform.length - 1))
        .floor()
        .clamp(0, sourceAudioWaveform.length - 1);
    final i1 = (endF * (sourceAudioWaveform.length - 1))
        .ceil()
        .clamp(i0 + 1, sourceAudioWaveform.length);
    final slice = sourceAudioWaveform.sublist(i0, i1);
    if (slice.isEmpty) return;

    final mid = rect.center.dy;
    final half = rect.height * 0.42;
    final barW = rect.width / slice.length;
    final paint = Paint()..color = const Color(0xFF3DDC97).withValues(alpha: 0.55);

    for (var i = 0; i < slice.length; i++) {
      final amp = slice[i].clamp(0.06, 1.0);
      final h = half * amp;
      final x = rect.left + i * barW;
      final w = math.max(1.0, barW * 0.72);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x + barW / 2, mid),
            width: w,
            height: h * 2,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  void _paintTextInScrollContent(
    Canvas canvas,
    Size size,
    double viewportHeight,
  ) {
    final textOrigin = musicContentHeight;
    final laneCount = overlays.isEmpty ? 1 : overlayLaneCount(overlays);
    for (var lane = 0; lane < laneCount; lane++) {
      final laneTop = textOrigin + lane * _laneStride;
      if (laneTop - lanesScrollY > viewportHeight ||
          laneTop - lanesScrollY + _laneHeight < 0) {
        continue;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, laneTop, size.width, laneTop + _laneHeight),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFF1A1F2A),
      );
    }

    for (final overlay in overlays) {
      if (overlay.id == selectedOverlayId) continue;
      _paintOverlayClip(canvas, size, overlay, selected: false);
    }
    for (final overlay in overlays) {
      if (overlay.id != selectedOverlayId) continue;
      _paintOverlayClip(canvas, size, overlay, selected: true);
    }
  }

  void _paintOverlayClip(
    Canvas canvas,
    Size size,
    TextOverlay overlay, {
    required bool selected,
  }) {
      final laneTop = musicContentHeight + overlay.lane * _laneStride;
      final viewportHeight = size.height - _scrollRegionTop;
      if (laneTop - lanesScrollY > viewportHeight ||
          laneTop - lanesScrollY + _laneHeight < 0) {
        return;
      }

      final span = overlayTimelineSpan(overlay, segments);
      if (span == null) return;

      final left = _x(span.start);
      final right = _x(span.end);
      if (right < 0 || left > size.width) return;

      final rect = Rect.fromLTRB(left, laneTop, right, laneTop + _laneHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = selected
              ? AppTheme.accent
              : Colors.white.withValues(alpha: 0.45),
      );
      _paintLaneLabel(canvas, rect, overlay.text);

      if (selected) {
        _drawHandle(
          canvas,
          left,
          top: laneTop,
          bottom: laneTop + _laneHeight,
          color: Colors.white,
          atStart: true,
        );
        _drawHandle(
          canvas,
          right,
          top: laneTop,
          bottom: laneTop + _laneHeight,
          color: Colors.white,
          atStart: false,
        );
        if (kDebugMode) {
          _paintDebugEdgeHitZone(
            canvas,
            left,
            top: laneTop,
            bottom: laneTop + _laneHeight,
            atStart: true,
          );
          _paintDebugEdgeHitZone(
            canvas,
            right,
            top: laneTop,
            bottom: laneTop + _laneHeight,
            atStart: false,
          );
        }
      }
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
        _scrollRegionTop + progress * (viewportHeight - thumbHeight);

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
    required bool atStart,
  }) {
    final rect = overlayEdgeHandleRect(x, top: top, bottom: bottom, atStart: atStart);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = color,
    );
    // CapCut-style grip cue down the middle of white trim caps.
    if (color == Colors.white) {
      final midX = rect.center.dx;
      canvas.drawLine(
        Offset(midX, rect.top + 5),
        Offset(midX, rect.bottom - 5),
        Paint()
          ..color = const Color(0x66000000)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// Visualizes the exact start/end hit rect (outside the clip) in debug.
  void _paintDebugEdgeHitZone(
    Canvas canvas,
    double edgeX, {
    required double top,
    required double bottom,
    required bool atStart,
  }) {
    canvas.drawRect(
      overlayEdgeHandleRect(edgeX, top: top, bottom: bottom, atStart: atStart),
      Paint()..color = const Color(0x59FFFF00), // yellow ~35% alpha
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
        oldDelegate.selectedMusicId != selectedMusicId ||
        oldDelegate.musicContentHeight != musicContentHeight ||
        oldDelegate.filmstripFrames != filmstripFrames ||
        oldDelegate.musicTracks != musicTracks ||
        oldDelegate.musicWaveforms != musicWaveforms ||
        oldDelegate.sourceAudioWaveform != sourceAudioWaveform ||
        oldDelegate.hasSourceAudio != hasSourceAudio ||
        oldDelegate.sourceDuration != sourceDuration ||
        oldDelegate.overlays != overlays;
  }
}
