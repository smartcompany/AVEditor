import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/music_picker_screen.dart';
import 'package:aveditor/screens/youtube_upload_screen.dart';
import 'package:aveditor/services/editor_history.dart';
import 'package:aveditor/services/audio_waveform_service.dart';
import 'package:aveditor/services/music_storage_service.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/timeline_thumbnail_service.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/music_timeline_ops.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/widgets/basic_text_edit_toolbar.dart';
import 'package:aveditor/widgets/export_progress_dialog.dart';
import 'package:aveditor/widgets/text_studio_panel.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:aveditor/widgets/transition_picker_sheet.dart';
import 'package:aveditor/widgets/transition_preview_compositor.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.projectId});

  final String projectId;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Gap + always-visible resize affordance between preview and dock.
  static const _dockResizeHandleHeight = 40.0;

  /// Drag speed past which the dock finishes in the flung direction.
  static const _dockFlingVelocity = 320.0;

  /// Physical decoder slots. [_controller]/[_auxController] flip via [_slotsSwapped]
  /// on transition handoff so we never seek the visible stream (avoids jumps).
  VideoPlayerController? _slotMain;
  VideoPlayerController? _slotAux;
  var _slotsSwapped = false;
  final _slotMainKey = GlobalKey();
  final _slotAuxKey = GlobalKey();

  VideoPlayerController? get _controller =>
      _slotsSwapped ? _slotAux : _slotMain;
  VideoPlayerController? get _auxController =>
      _slotsSwapped ? _slotMain : _slotAux;

  /// Aux opacity while a fade is active; null when not fading.
  double? _fadeProgress;

  /// Highest blend progress seen for the current cut — decoder position can
  /// jitter backward a few ms and that made slide transforms tremble.
  double _fadeProgressPeak = 0;

  /// Wall-clock anchor so slide/push progress advances smoothly while playing
  /// instead of tracking noisy decoder timestamps.
  DateTime? _fadeWallClockStart;
  double _fadeWallClockStartT = 0;

  /// Last fade window driven this playthrough (for handoff past [outgoing.end]).
  PreviewFadeWindow? _activeFade;

  /// Cut index whose aux stream is already anchored (avoid per-tick reseek).
  int? _fadeAnchoredAfterIndex;

  /// True while [_completeFadeHandoff] is awaiting the main seek settle.
  var _fadeHandoffInFlight = false;

  /// Serializes aux seeks so overlapping fade ticks don't race.
  int _fadeSyncGen = 0;

  /// Native Video Engine spatial preview (AVFoundation/Metal · Media3/GPU).
  var _spatialPreviewActive = false;
  int _spatialPreviewGen = 0;
  int? _spatialTextureId;
  StreamSubscription<Duration>? _spatialPositionSub;
  StreamSubscription<bool>? _spatialPlayingSub;

  /// CapCut-style lookahead: warm decoders before the fade window opens.
  static const _cutPrewarmLookahead = Duration(milliseconds: 600);
  int? _nativePrewarmedCutIndex;
  int _nativePrewarmGen = 0;
  var _spatialFrameReady = false;
  int? _auxPrewarmedCutIndex;
  int _auxPrewarmGen = 0;

  /// Continuous native composition preview (FrameResolver + VT/MediaCodec).
  var _nativeTimelineActive = false;
  int _nativeTimelineGen = 0;
  Timer? _nativeTimelineRebuildDebounce;
  StreamSubscription<Duration>? _nativeTimelinePosSub;
  StreamSubscription<bool>? _nativeTimelinePlayingSub;
  Duration? _pendingNativeScrub;
  var _nativeScrubInFlight = false;

  /// Pause once the main playhead reaches this time (transition-length preview).
  Duration? _transitionPreviewUntil;

  /// Bumped to cancel an in-flight [_previewTransitionAtCut] (e.g. panel close).
  int _transitionPreviewGen = 0;

  /// Cut index while the docked transition studio is open; null when closed.
  int? _transitionStudioCutIndex;

  VideoProject? _project;
  String? _selectedOverlayId;
  String? _selectedSegmentId;
  String? _selectedMusicId;
  int? _selectedTransitionAfterIndex;

  /// Overlay currently edited inline on the preview (keyboard open).
  String? _editingOverlayId;

  /// When true, the next inline-edit focus selects all (fresh basic-text add).
  var _inlineEditSelectAll = false;

  /// CapCut-style text studio is open for this overlay id.
  String? _textStudioOverlayId;
  bool _ready = false;
  bool _exporting = false;
  bool _applyingHistory = false;
  String? _errorMessage;

  /// Optimistic playhead while `seekTo` is in flight (avoids timeline jitter).
  Duration? _scrubPlayhead;

  /// True while a trim/resize edge drag is previewing frames without moving
  /// the centre playhead.
  bool _edgeFramePreviewActive = false;
  Duration? _lastEdgePreviewSeek;

  final _export = ExportService();
  final _exportSave = ExportSaveService();
  final _settings = const AppSettingsService();
  final _projectStorage = const ProjectStorageService();
  final _history = EditorHistory();
  final _thumbnailService = const TimelineThumbnailService();
  final _probe = const VideoProbeService();
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();
  final _timelineKey = GlobalKey<TimelineWidgetState>();
  final _editorBodyKey = GlobalKey();
  final _musicPlayer = AudioPlayer();

  /// Last music clip loaded into [_musicPlayer]; null when stopped.
  String? _syncedMusicId;
  int _musicSyncGen = 0;

  List<TimelineFilmstripFrame> _filmstripFrames = [];
  final Map<String, List<double>> _musicWaveforms = {};
  List<double> _sourceAudioWaveform = const [];
  bool _hasSourceAudio = false;

  Timer? _saveDebounce;

  /// Bottom-dock height.
  ///
  /// - `null` → **entry / mid**: dock = 1/3 screen
  /// - `0` → full video (dock hidden)
  /// - `> 0` → explicit height while dragging or expanded to ~2/3 screen
  final ValueNotifier<double?> _dockHeight = ValueNotifier(null);
  AnimationController? _dockSnapAnim;
  Completer<void>? _dockAnimCompleter;
  double _dockAnimFrom = 0;
  double _dockAnimTo = 0;

  /// Bottom-of-preview drag strip: grow / shrink the dock vs the video.
  final ValueNotifier<bool> _previewMaximizeEdgeLit = ValueNotifier(false);
  int? _previewMaximizeEdgePointer;
  VelocityTracker? _previewMaximizeEdgeVelocity;

  Duration get _playhead {
    if (_scrubPlayhead != null) return _scrubPlayhead!;
    if (_nativeTimelineActive && NativeVideoEngine.instance.isTimelineMode) {
      final project = _project;
      if (project != null) {
        // Preview clock == sum of segment durations (same as timeline strip).
        return exportTimeToSourceTime(
          project.segments,
          NativeVideoEngine.instance.position,
        );
      }
    }
    return _controller?.value.position ?? Duration.zero;
  }

  bool get _isPreviewPlaying {
    if (_nativeTimelineActive && NativeVideoEngine.instance.isTimelineMode) {
      return NativeVideoEngine.instance.isPlaying;
    }
    return _controller?.value.isPlaying ?? false;
  }

  /// Timeline playhead during a dual-layer transition.
  ///
  /// Packed timeline time does not overlap clips, but preview plays outgoing
  /// tail and incoming head in the same wall-clock window. Mapping the live
  /// decoder position alone therefore crawls to the cut, then jumps ~[td]
  /// into the next clip at handoff. Remap with [t] so the playhead advances
  /// continuously across both halves and lands where the swapped controller is.
  Duration get _timelinePlayhead {
    if (_nativeTimelineActive && NativeVideoEngine.instance.isTimelineMode) {
      return _playhead;
    }
    final project = _project;
    final fade = _activeFade;
    if (project == null || fade == null || fade.td <= Duration.zero) {
      return _playhead;
    }
    final cut = cutExportTimeAfter(project.segments, fade.afterIndex);
    final t = _fadeHandoffInFlight ? 1.0 : (_fadeProgress ?? fade.t);
    final traveledMs = (t * 2 * fade.td.inMilliseconds).round().clamp(
      0,
      1 << 30,
    );
    final sequenceTime = cut - fade.td + Duration(milliseconds: traveledMs);
    return exportTimeToSourceTime(project.segments, sequenceTime);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initVideo();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Keyboard animation — rebuild so the editing lift tracks the IME.
    if (_editingOverlayId != null && mounted) setState(() {});
  }

  double _bodyHeight() {
    final bodyBox = _editorBodyKey.currentContext?.findRenderObject();
    if (bodyBox is RenderBox && bodyBox.hasSize) return bodyBox.size.height;
    if (!mounted) return 800;
    return MediaQuery.sizeOf(context).height;
  }

  /// Dock may not consume the full body — the resize handle sits above it.
  double _availableDockHeight() {
    return (_bodyHeight() - _dockResizeHandleHeight).clamp(
      0.0,
      double.infinity,
    );
  }

  /// Expanded dock ceiling = 2/3 of the screen.
  double _maxDockHeight() {
    if (!mounted) return 800 * EditorSheetMetrics.maxFractionValue;
    final metrics = EditorSheetMetrics.of(context);
    return metrics.maxHeight.clamp(0.0, _availableDockHeight());
  }

  /// Mid / initial dock = 1/3 of the screen.
  double _entryDockHeight() {
    final maxH = _maxDockHeight();
    if (!mounted) {
      return (800 * EditorSheetMetrics.entryFractionValue).clamp(0.0, maxH);
    }
    final metrics = EditorSheetMetrics.of(context);
    return metrics.entryHeight.clamp(0.0, maxH);
  }

  /// Pixel height used while dragging / snapping (resolves `null` entry).
  double _dockHeightPx() {
    final h = _dockHeight.value;
    if (h != null) return h;
    return _entryDockHeight();
  }

  void _stopDockSnapAnim() {
    _dockSnapAnim?.dispose();
    _dockSnapAnim = null;
    final pending = _dockAnimCompleter;
    _dockAnimCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  /// Make height explicit before drag so we can animate in pixels.
  void _ensureDockHeightExplicit() {
    if (_dockHeight.value != null) return;
    _dockHeight.value = _entryDockHeight();
  }

  /// [height] `null` restores entry (1/3 screen); otherwise pixels (0 = hidden).
  Future<void> _setDockHeight(
    double? height, {
    bool animate = false,
    Duration duration = const Duration(milliseconds: 220),
    Curve? curve,
  }) async {
    final maxH = _maxDockHeight();
    final double? target;
    if (height == null) {
      target = null;
    } else {
      target = height.clamp(0.0, maxH);
    }

    if (!animate) {
      _stopDockSnapAnim();
      _dockHeight.value = target;
      return;
    }

    final from = _dockHeightPx();
    final to = target ?? _entryDockHeight();
    _dockAnimFrom = from;
    _dockAnimTo = to;
    final settleToEntry = height == null;
    if ((to - from).abs() < 0.5) {
      _dockHeight.value = settleToEntry ? null : to;
      return;
    }
    _stopDockSnapAnim();
    final expandish = to >= from;
    final controller = AnimationController(vsync: this, duration: duration);
    _dockSnapAnim = controller;
    final anim = CurvedAnimation(
      parent: controller,
      curve: curve ?? (expandish ? Curves.easeOutCubic : Curves.easeInCubic),
    );
    final done = Completer<void>();
    _dockAnimCompleter = done;
    anim.addListener(() {
      _dockHeight.value =
          _dockAnimFrom + (_dockAnimTo - _dockAnimFrom) * anim.value;
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        _dockHeight.value = settleToEntry ? null : _dockAnimTo;
        final pending = _dockAnimCompleter;
        _dockAnimCompleter = null;
        _dockSnapAnim?.dispose();
        _dockSnapAnim = null;
        if (pending != null && !pending.isCompleted) {
          pending.complete();
        }
      }
    });
    await controller.forward();
    await done.future;
  }

  /// Show text / transition studio without touching dock height or timeline state.
  void _presentStudioDock(VoidCallback applyStudioState) {
    FocusManager.instance.primaryFocus?.unfocus();
    applyStudioState();
  }

  /// Hide studio and return to the existing timeline chrome as-is.
  Future<void> _dismissStudioDock(VoidCallback clearStudioState) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    clearStudioState();
  }

  void _clearTextStudioHeightOverride() {
    // Dock height is shared; closing studio keeps the current snap stage.
  }

  void _onChromeDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta;
    if (delta == null) return;
    _stopDockSnapAnim();
    _ensureDockHeightExplicit();
    final maxH = _maxDockHeight();
    _dockHeight.value = (_dockHeightPx() - delta).clamp(0.0, maxH);
  }

  void _onChromeDragEnd(DragEndDetails details) {
    _settleDockHeight(velocity: details.primaryVelocity ?? 0);
  }

  /// Snap dock: hidden ↔ entry (1/3) ↔ max (2/3).
  void _settleDockHeight({required double velocity}) {
    final current = _dockHeightPx();
    final entry = _entryDockHeight();
    final maxH = _maxDockHeight();
    final target = snapDockHeight(
      current: current,
      velocity: velocity,
      stops: dockHeightStops(entryHeight: entry, maxHeight: maxH),
      flingVelocity: _dockFlingVelocity,
    );
    if ((target - entry).abs() <= 8) {
      unawaited(_setDockHeight(null, animate: true));
    } else {
      unawaited(_setDockHeight(target, animate: true));
    }
  }

  void _onPreviewMaximizePointerDown(PointerDownEvent event) {
    // Text overlays in the lower preview fifth share this hit zone — yield so
    // dragging text never also resizes the dock.
    if (_previewKey.currentState?.claimsOverlayPointer(event) == true) {
      return;
    }
    _stopDockSnapAnim();
    _ensureDockHeightExplicit();
    _previewMaximizeEdgePointer = event.pointer;
    _previewMaximizeEdgeVelocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPreviewMaximizePointerMove(PointerMoveEvent event) {
    if (event.pointer != _previewMaximizeEdgePointer) return;
    final preview = _previewKey.currentState;
    if (preview != null && preview.isHandlingOverlayPointer(event.pointer)) {
      _previewMaximizeEdgePointer = null;
      _previewMaximizeEdgeVelocity = null;
      _previewMaximizeEdgeLit.value = false;
      return;
    }
    _previewMaximizeEdgeVelocity?.addPosition(event.timeStamp, event.position);
    if (!_previewMaximizeEdgeLit.value && event.delta.dy.abs() > 0.5) {
      _previewMaximizeEdgeLit.value = true;
    }
    final maxH = _maxDockHeight();
    _dockHeight.value = (_dockHeightPx() - event.delta.dy).clamp(0.0, maxH);
  }

  void _onPreviewMaximizePointerEnd(PointerEvent event) {
    if (event.pointer != _previewMaximizeEdgePointer) return;
    final velocity =
        _previewMaximizeEdgeVelocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    _previewMaximizeEdgePointer = null;
    _previewMaximizeEdgeVelocity = null;
    _previewMaximizeEdgeLit.value = false;
    _settleDockHeight(velocity: velocity);
  }

  /// Always-visible strip between the video and the control dock.
  ///
  /// Arrows: up when fully collapsed, down when at 2/3 max, both in the
  /// middle (panel) stage. Drag hit-testing also covers the preview's lower
  /// fifth via [_buildPreviewDockDragEdge].
  Widget _buildDockResizeHandle({required bool enabled}) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ValueListenableBuilder<double?>(
      valueListenable: _dockHeight,
      builder: (context, dockH, _) {
        final entry = _entryDockHeight();
        final maxH = _maxDockHeight();
        final px = dockH ?? entry;
        final atHidden = dockH != null && dockH <= 0.5;
        final atMax = dockH != null && dockH >= maxH - 24;
        final t = entry <= 0 ? 0.0 : (px / entry).clamp(0.0, 1.0);
        final bottomInset = safeBottom * (1 - t);

        Widget arrows() {
          final color = Colors.white.withValues(alpha: 0.75);
          if (atHidden) {
            return Icon(
              Icons.keyboard_arrow_up_rounded,
              color: color,
              size: 26,
            );
          }
          if (atMax) {
            return Icon(
              Icons.keyboard_arrow_down_rounded,
              color: color,
              size: 26,
            );
          }
          // Panel / mid stage — both directions are available.
          return Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.keyboard_arrow_up_rounded, color: color, size: 18),
              Icon(Icons.keyboard_arrow_down_rounded, color: color, size: 18),
            ],
          );
        }

        final strip = SizedBox(
          height: _dockResizeHandleHeight + bottomInset,
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: ValueListenableBuilder<bool>(
              valueListenable: _previewMaximizeEdgeLit,
              builder: (context, lit, _) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: lit ? 0.22 : 0.06),
                        Colors.black.withValues(alpha: lit ? 0.45 : 0.14),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: Center(child: arrows()),
                );
              },
            ),
          ),
        );

        if (!enabled) return strip;

        return Semantics(
          label: atHidden
              ? context.l10n.showTimeline
              : context.l10n.hideTimeline,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPreviewMaximizePointerDown,
            onPointerMove: _onPreviewMaximizePointerMove,
            onPointerUp: _onPreviewMaximizePointerEnd,
            onPointerCancel: _onPreviewMaximizePointerEnd,
            child: strip,
          ),
        );
      },
    );
  }

  /// Lower fifth of the preview — extends the dock-resize drag target and
  /// shows the drag gradient over the video.
  Widget _buildPreviewDockDragEdge({required double zoneHeight}) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: zoneHeight,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPreviewMaximizePointerDown,
        onPointerMove: _onPreviewMaximizePointerMove,
        onPointerUp: _onPreviewMaximizePointerEnd,
        onPointerCancel: _onPreviewMaximizePointerEnd,
        child: ValueListenableBuilder<bool>(
          valueListenable: _previewMaximizeEdgeLit,
          builder: (context, lit, _) {
            return IgnorePointer(
              child: AnimatedOpacity(
                opacity: lit ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.55),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _initVideo() async {
    try {
      final stored = await _projectStorage.load(widget.projectId);
      if (stored == null) {
        if (!mounted) return;
        setState(() {
          _ready = true;
          _errorMessage = 'project_not_found';
        });
        return;
      }

      final controller = VideoPlayerController.file(File(stored.sourcePath));
      await controller.initialize();
      controller.setLooping(false);
      controller.addListener(_onVideoTick);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      final duration = controller.value.duration;
      final project = stored.duration == Duration.zero
          ? VideoProject(
              id: stored.id,
              sourcePath: stored.sourcePath,
              duration: duration,
              trim: ClipTrim(start: Duration.zero, end: duration),
              // Keep any cuts already saved before duration was known.
              segments: List<ClipSegment>.from(stored.segments),
              overlays: stored.overlays,
              musicTracks: List<ProjectMusic>.from(stored.musicTracks),
              preset: stored.preset,
              rotation: stored.rotation,
              updatedAt: stored.updatedAt,
            )
          : stored;

      // Normalize a copy first — clearing in place then reading the same list
      // would wipe cuts (empty → single full-length segment).
      final normalized = normalizeSegments(
        List<ClipSegment>.from(project.segments),
        sourceDuration: duration,
      );
      project.segments
        ..clear()
        ..addAll(
          normalized.isEmpty || totalKeptDuration(normalized) <= Duration.zero
              ? segmentsFromTrim(start: Duration.zero, end: duration)
              : normalized,
        );

      setState(() {
        _slotMain = controller;
        _slotsSwapped = false;
        _project = project;
        _ready = true;
        _errorMessage = null;
      });

      unawaited(_ensureNativeTimeline());
      unawaited(_loadFilmstrip(project.sourcePath, project.duration));
      unawaited(_loadMusicWaveforms(project));
      unawaited(_loadSourceAudioWaveform(project.sourcePath));

      if (stored.duration == Duration.zero) {
        _scheduleSave();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _loadFilmstrip(String sourcePath, Duration duration) async {
    final frames = await _thumbnailService.loadFilmstrip(
      videoPath: sourcePath,
      duration: duration,
    );
    if (!mounted) {
      for (final frame in frames) {
        frame.image.dispose();
      }
      return;
    }
    for (final frame in _filmstripFrames) {
      frame.image.dispose();
    }
    setState(() => _filmstripFrames = frames);
  }

  void _disposeFilmstrip() {
    for (final frame in _filmstripFrames) {
      frame.image.dispose();
    }
    _filmstripFrames = [];
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistProject());
    });
  }

  void _scheduleNativeTimelineRebuild() {
    _nativeTimelineRebuildDebounce?.cancel();
    _nativeTimelineRebuildDebounce = Timer(const Duration(milliseconds: 280), () {
      unawaited(_ensureNativeTimeline());
    });
  }

  /// CapCut-style: native composition owns preview frames; VideoPlayer is fallback.
  Future<void> _ensureNativeTimeline({Duration? seekComposition}) async {
    final project = _project;
    if (project == null || !NativeVideoEngine.supportsTimeline) {
      _nativeTimelineActive = false;
      return;
    }
    if (project.segments.isEmpty) return;

    final gen = ++_nativeTimelineGen;
    final wasPlaying = NativeVideoEngine.instance.isPlaying ||
        (_controller?.value.isPlaying ?? false);
    final resumeAt = seekComposition ??
        (NativeVideoEngine.instance.isTimelineMode
            ? NativeVideoEngine.instance.position
            : (sourceTimeToExportTime(
                  project.segments,
                  _playhead,
                ) ??
                Duration.zero));

    final textureId = await NativeVideoEngine.instance.prepareTimeline(
      sourcePath: project.sourcePath,
      segments: project.segments,
      rotationRadians: project.rotation,
    );
    if (!mounted || gen != _nativeTimelineGen) return;

    if (textureId == null) {
      _nativeTimelineActive = false;
      await _nativeTimelinePosSub?.cancel();
      await _nativeTimelinePlayingSub?.cancel();
      _nativeTimelinePosSub = null;
      _nativeTimelinePlayingSub = null;
      if (mounted) setState(() {});
      return;
    }

    final ready = await NativeVideoEngine.instance.preroll(resumeAt);
    if (!mounted || gen != _nativeTimelineGen) return;

    if (!ready) {
      _nativeTimelineActive = false;
      await NativeVideoEngine.instance.dispose();
      if (mounted) setState(() {});
      return;
    }

    // Native owns both picture and source audio. Mute VideoPlayer completely.
    try {
      await _auxController?.pause();
      await _auxController?.setVolume(0);
      await _controller?.pause();
      await _controller?.setVolume(0);
    } catch (_) {}

    await _nativeTimelinePosSub?.cancel();
    await _nativeTimelinePlayingSub?.cancel();
    _nativeTimelinePosSub =
        NativeVideoEngine.instance.positionStream.listen((_) {
      if (!mounted) return;
      unawaited(_syncMusicOnTick());
      setState(() {});
    });
    _nativeTimelinePlayingSub =
        NativeVideoEngine.instance.playingStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });

    _nativeTimelineActive = true;
    _spatialPreviewActive = false;
    _spatialFrameReady = false;
    _clearFadeProgress();
    _activeFade = null;
    _fadeAnchoredAfterIndex = null;

    if (wasPlaying) {
      await NativeVideoEngine.instance.play();
    }
    unawaited(_syncMusicPlayback());
    if (mounted) setState(() {});
  }

  Future<void> _persistProject() async {
    final project = _project;
    if (project == null) return;
    await _projectStorage.save(project);
  }

  EditorSnapshot _snapshot() {
    return EditorSnapshot.fromProject(
      _project!,
      selectedSegmentId: _selectedSegmentId,
      selectedOverlayId: _selectedOverlayId,
      selectedMusicId: _selectedMusicId,
    );
  }

  void _mutate(void Function(VideoProject project) apply) {
    final project = _project;
    if (project == null || _applyingHistory) return;
    final rollback = _snapshot();
    _history.record(rollback);
    try {
      apply(project);
      setState(() {});
      _scheduleSave();
      _scheduleNativeTimelineRebuild();
    } catch (error) {
      rollback.applyTo(project);
      rethrow;
    }
  }

  void _ensureHealthySegments(VideoProject project) {
    if (project.duration <= Duration.zero) return;

    var fixed = normalizeSegments(
      project.segments,
      sourceDuration: project.duration,
    );
    if (fixed.isEmpty || totalKeptDuration(fixed) <= Duration.zero) {
      fixed = segmentsFromTrim(start: Duration.zero, end: project.duration);
    }

    if (fixed.length != project.segments.length ||
        !_segmentsMatch(project.segments, fixed)) {
      project.segments
        ..clear()
        ..addAll(fixed);
    }
  }

  bool _segmentsMatch(List<ClipSegment> a, List<ClipSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }

  Duration _sequenceTimeForSplit(
    List<ClipSegment> segments,
    Duration rawPlayhead,
  ) {
    final kept = totalKeptDuration(segments);
    if (kept <= Duration.zero) return Duration.zero;

    var sequenceTime = timelinePlayheadFromSource(segments, rawPlayhead);
    if (sequenceTime >= kept) {
      sequenceTime = kept - const Duration(milliseconds: 100);
    }
    if (sequenceTime < Duration.zero) {
      sequenceTime = Duration.zero;
    }
    return sequenceTime;
  }

  void _undo() {
    final project = _project;
    if (project == null || _applyingHistory) return;
    final previous = _history.undo(_snapshot());
    if (previous == null) return;
    _applyingHistory = true;
    previous.applyTo(project);
    _selectedSegmentId = previous.selectedSegmentId;
    _selectedOverlayId = previous.selectedOverlayId;
    _selectedMusicId = previous.selectedMusicId;
    if (_textStudioOverlayId != null && _textStudioOverlay == null) {
      _textStudioOverlayId = null;
    }
    _applyingHistory = false;
    setState(() {});
    _scheduleSave();
    unawaited(_syncMusicPlayback());
  }

  void _redo() {
    final project = _project;
    if (project == null || _applyingHistory) return;
    final next = _history.redo(_snapshot());
    if (next == null) return;
    _applyingHistory = true;
    next.applyTo(project);
    _selectedSegmentId = next.selectedSegmentId;
    _selectedOverlayId = next.selectedOverlayId;
    _selectedMusicId = next.selectedMusicId;
    if (_textStudioOverlayId != null && _textStudioOverlay == null) {
      _textStudioOverlayId = null;
    }
    _applyingHistory = false;
    setState(() {});
    _scheduleSave();
    unawaited(_syncMusicPlayback());
  }

  void _splitAtPlayhead() {
    final project = _project;
    if (project == null || _exporting) return;
    if (project.duration <= Duration.zero) return;

    // Non-video track selected and playhead inside it → split that item.
    // Otherwise (or playhead outside the selection) → split the video.
    if (_trySplitSelectedMusic()) return;
    if (_trySplitSelectedOverlay()) return;

    _splitVideoAtPlayhead();
  }

  /// Returns true when a music clip was split.
  bool _trySplitSelectedMusic() {
    final project = _project;
    final id = _selectedMusicId;
    if (project == null || id == null) return false;

    final index = project.musicTracks.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    final clip = project.musicTracks[index];
    if (_playhead < clip.timelineStart || _playhead >= clip.timelineEnd) {
      return false;
    }

    final split = splitMusicClip(clip, _playhead);
    if (split == null) {
      _showSnack(context.l10n.splitTooShort);
      return true;
    }
    _mutate((p) {
      p.musicTracks
        ..removeAt(index)
        ..insert(index, split.$1)
        ..insert(index + 1, split.$2);
      final compacted = compactMusicLanes(p.musicTracks);
      p.musicTracks
        ..clear()
        ..addAll(compacted);
      _selectedMusicId = split.$2.id;
    });
    return true;
  }

  /// Returns true when a text overlay was split.
  bool _trySplitSelectedOverlay() {
    final project = _project;
    final id = _selectedOverlayId;
    if (project == null || id == null) return false;

    final index = project.overlays.indexWhere((o) => o.id == id);
    if (index < 0) return false;
    final overlay = project.overlays[index];
    if (_playhead < overlay.start || _playhead >= overlay.end) {
      return false;
    }

    final split = splitTextOverlay(overlay, _playhead);
    if (split == null) {
      _showSnack(context.l10n.splitTooShort);
      return true;
    }

    _mutate((p) {
      p.overlays
        ..removeAt(index)
        ..insert(index, split.$1)
        ..insert(index + 1, split.$2);
      final compacted = compactOverlayLanes(p.overlays);
      p.overlays
        ..clear()
        ..addAll(compacted);
      _selectedOverlayId = split.$2.id;
      _editingOverlayId = null;
      _selectedSegmentId = null;
      _selectedMusicId = null;
    });
    return true;
  }

  void _splitVideoAtPlayhead() {
    final project = _project;
    if (project == null) return;

    _ensureHealthySegments(project);

    final rawPlayhead = _playhead;
    final working = List<ClipSegment>.from(project.segments);
    final sequenceTime = _sequenceTimeForSplit(working, rawPlayhead);
    final playhead = splitSourceFromSequence(working, sequenceTime);

    try {
      if (!isInKeptRegion(working, playhead)) {
        throw StateError('split_out_of_range');
      }

      final splitPoint = resolveSplitPoint(working, playhead);
      if (isAlreadySplitAt(working, splitPoint)) {
        OverlayEventLog.log('split', 'already_split', {
          'sequenceTime': sequenceTime,
          'splitPoint': splitPoint,
        });
        return;
      }

      OverlayEventLog.log('split', 'attempt', {
        'rawPlayhead': rawPlayhead,
        'sequenceTime': sequenceTime,
        'playhead': playhead,
        'splitPoint': splitPoint,
        'segmentCount': working.length,
        'segmentDurations': working
            .map((segment) => segment.duration.inMilliseconds)
            .join(','),
      });

      final newSegments = splitSegmentsAt(working, splitPoint);
      ClipSegment? rightPiece;
      for (final segment in newSegments) {
        if (segment.start == splitPoint) {
          rightPiece = segment;
          break;
        }
      }

      _mutate((p) {
        p.segments
          ..clear()
          ..addAll(newSegments);
        _selectedSegmentId = (rightPiece ?? newSegments.last).id;
        _selectedOverlayId = null;
        _selectedMusicId = null;
      });
      OverlayEventLog.log('split', 'success', {
        'sequenceTime': sequenceTime,
        'newSegmentCount': project.segments.length,
      });
    } on StateError catch (e) {
      OverlayEventLog.log('split', 'failed', {
        'code': e.message,
        'rawPlayhead': rawPlayhead,
        'sequenceTime': sequenceTime,
        'segmentDurations': project.segments
            .map((segment) => segment.duration.inMilliseconds)
            .join(','),
      });
      _showSnack(_splitErrorMessage(e.message));
    }
  }

  void _deleteSelectedSegment() {
    final project = _project;
    final segmentId = _selectedSegmentId;
    if (project == null || segmentId == null || _exporting) return;

    try {
      final updated = deleteSegment(project.segments, segmentId);
      _mutate((p) {
        p.segments
          ..clear()
          ..addAll(updated);
        _selectedSegmentId = null;
      });
    } on StateError catch (e) {
      _showSnack(_splitErrorMessage(e.message));
    }
  }

  String _splitErrorMessage(String code) {
    final l10n = context.l10n;
    return switch (code) {
      'split_too_short' => l10n.splitTooShort,
      'split_out_of_range' => l10n.splitOutOfRange,
      'cannot_delete_last_segment' => l10n.cannotDeleteLastSegment,
      'segment_too_short' => l10n.splitTooShort,
      _ => l10n.splitFailed,
    };
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _advancePlaybackPastGaps() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null || !controller.value.isPlaying) {
      return;
    }
    // Native timeline packs gaps/transitions itself — do not seek VideoPlayer.
    if (_nativeTimelineActive) return;
    if (_fadeHandoffInFlight) return;

    final pos = controller.value.position;
    final fade = previewFadeAt(project.segments, pos);
    if (fade != null) {
      final entering = _fadeAnchoredAfterIndex != fade.afterIndex;
      _activeFade = fade;
      if (NativeVideoEngine.isSpatialPreview(fade.outgoing.transition)) {
        if (NativeVideoEngine.supports(fade.outgoing.transition)) {
          if (entering) {
            _fadeProgressPeak = fade.t;
            _fadeWallClockStart = null;
          }
          if (entering || !_spatialPreviewActive) {
            unawaited(
              _showSpatialPreviewAt(
                fade,
                playing: controller.value.isPlaying,
              ),
            );
          } else {
            if (controller.value.isPlaying && _fadeWallClockStart == null) {
              _beginFadeWallClock(_fadeProgress ?? fade.t);
            }
            _setFadeProgress(fade.t, playing: controller.value.isPlaying);
          }
          return;
        }
        // Unsupported spatial effect — Flutter dual-layer fallback.
      }
      if (entering) {
        unawaited(_tearDownSpatialPreview());
        _fadeProgressPeak = fade.t;
        _fadeWallClockStart = null;
      }
      if (entering || _auxController == null) {
        unawaited(_startFlutterFadePreview(fade, entering: entering));
      } else {
        if (controller.value.isPlaying && _fadeWallClockStart == null) {
          _beginFadeWallClock(_fadeProgress ?? fade.t);
        }
        _setFadeProgress(fade.t, playing: controller.value.isPlaying);
        final aux = _auxController;
        if (aux != null &&
            aux.value.isInitialized &&
            controller.value.isPlaying &&
            !aux.value.isPlaying) {
          unawaited(aux.play());
        }
      }
      return;
    }

    _maybePrewarmUpcomingCut(project, pos, controller.value.isPlaying);

    if (_activeFade != null) {
      final active = _activeFade!;
      // Past the outgoing end → hand off to the incoming side once.
      if (pos >= active.outgoing.end) {
        if (!_fadeHandoffInFlight) {
          if (_spatialPreviewActive) {
            unawaited(_completeSpatialHandoff(active));
          } else {
            unawaited(_completeFadeHandoff(active));
          }
        }
        return;
      }
      // Still inside the fade span but previewFadeAt missed a frame — keep going.
      final windowStart = active.outgoing.end - active.td;
      if (pos >= windowStart && pos < active.outgoing.end) {
        final span = active.td.inMilliseconds;
        final t = span <= 0
            ? 1.0
            : ((pos.inMilliseconds - windowStart.inMilliseconds) / span).clamp(
                0.0,
                1.0,
              );
        final continued = PreviewFadeWindow(
          afterIndex: active.afterIndex,
          t: t,
          outgoing: active.outgoing,
          incoming: active.incoming,
          td: active.td,
        );
        _activeFade = continued;
        _setFadeProgress(t, playing: controller.value.isPlaying);
        return;
      }
      unawaited(_tearDownFadePreview());
    }

    if (isInKeptRegion(project.segments, pos)) {
      final segment = segmentAt(project.segments, pos);
      if (segment != null &&
          pos >= segment.end - const Duration(milliseconds: 80)) {
        final next = nextSegmentStartAfter(project.segments, pos);
        if (next != null) {
          // Soft-cut (dual-layer) is handled above; remaining cuts stay hard seeks.
          final idx = project.segments.indexWhere((s) => s.id == segment.id);
          final incoming = idx >= 0 && idx < project.segments.length - 1
              ? project.segments[idx + 1]
              : null;
          if (incoming != null && previewUsesFade(segment, incoming)) {
            return;
          }
          // Guard: never hard-seek while a dual-layer handoff is in flight.
          if (_fadeAnchoredAfterIndex != null) return;
          // Contiguous source (simple split / cleared transition): keep rolling.
          // Seeking to the next start here pauses/rebuffers and feels like a hitch.
          if (next <= segment.end + const Duration(milliseconds: 16)) {
            return;
          }
          controller.seekTo(next);
          unawaited(_syncMusicPlayback());
        } else {
          controller.pause();
          controller.seekTo(segment.end);
          unawaited(_syncMusicPlayback());
        }
      }
      return;
    }

    final next = nextSegmentStartAfter(project.segments, pos);
    if (next != null) {
      controller.seekTo(next);
      unawaited(_syncMusicPlayback());
    } else {
      final last = project.segments.last;
      controller.pause();
      controller.seekTo(last.end);
      unawaited(_syncMusicPlayback());
    }
  }

  /// Commit dual-layer blend progress. While playing, drive [t] from wall
  /// clock only — mixing decoder timestamps caused forward spikes.
  void _setFadeProgress(double t, {required bool playing}) {
    var clamped = t.clamp(0.0, 1.0);
    if (playing) {
      final wallStart = _fadeWallClockStart;
      final active = _activeFade;
      if (wallStart != null && active != null && active.td > Duration.zero) {
        final elapsedUs = DateTime.now().difference(wallStart).inMicroseconds;
        final tdUs = active.td.inMicroseconds;
        clamped = (_fadeWallClockStartT + elapsedUs / tdUs).clamp(0.0, 1.0);
      }
      final next = clamped < _fadeProgressPeak ? _fadeProgressPeak : clamped;
      _fadeProgressPeak = next;
      _syncNativeSpatialSeek(next);
      if (_fadeProgress == next) return;
      setState(() => _fadeProgress = next);
      return;
    }
    _fadeWallClockStart = null;
    _fadeProgressPeak = clamped;
    _syncNativeSpatialSeek(clamped);
    if (_fadeProgress == clamped) return;
    setState(() => _fadeProgress = clamped);
  }

  void _maybePrewarmUpcomingCut(
    VideoProject project,
    Duration pos,
    bool playing,
  ) {
    if (!playing || _fadeHandoffInFlight || _spatialPreviewActive) return;

    for (var i = 0; i < project.segments.length - 1; i++) {
      final outgoing = project.segments[i];
      final incoming = project.segments[i + 1];
      if (!previewUsesFade(outgoing, incoming)) continue;

      final td = clampedTransitionDuration(outgoing, next: incoming);
      if (td <= Duration.zero) continue;

      final windowStart = outgoing.end - td;
      final prewarmStart = windowStart - _cutPrewarmLookahead;
      if (pos < prewarmStart || pos >= windowStart) continue;

      final transition = outgoing.transition;
      if (transition != null && NativeVideoEngine.supports(transition)) {
        if (_nativePrewarmedCutIndex != i) {
          unawaited(_prewarmNativeCut(i));
        }
      } else if (_auxPrewarmedCutIndex != i) {
        unawaited(_prewarmAuxCut(i));
      }
      return;
    }
  }

  Future<void> _prewarmNativeCut(int cutIndex) async {
    final project = _project;
    if (project == null || cutIndex >= project.segments.length - 1) return;

    final outgoing = project.segments[cutIndex];
    final incoming = project.segments[cutIndex + 1];
    final transition = outgoing.transition;
    if (transition == null || !NativeVideoEngine.supports(transition)) return;

    if (_nativePrewarmedCutIndex == cutIndex &&
        NativeVideoEngine.instance.isActive &&
        NativeVideoEngine.instance.hasFrame) {
      return;
    }

    final gen = ++_nativePrewarmGen;
    final textureId = await NativeVideoEngine.instance.prepareTransition(
      sourcePath: project.sourcePath,
      outgoing: outgoing,
      incoming: incoming,
      transition: transition,
    );
    if (!mounted || gen != _nativePrewarmGen) return;

    if (textureId == null) {
      _nativePrewarmedCutIndex = null;
      return;
    }

    final ready = await NativeVideoEngine.instance.preroll(Duration.zero);
    if (!mounted || gen != _nativePrewarmGen) return;

    if (ready) {
      _nativePrewarmedCutIndex = cutIndex;
    } else {
      _nativePrewarmedCutIndex = null;
      await NativeVideoEngine.instance.dispose();
    }
  }

  Future<void> _prewarmAuxCut(int cutIndex) async {
    final project = _project;
    if (project == null || cutIndex >= project.segments.length - 1) return;

    final outgoing = project.segments[cutIndex];
    final incoming = project.segments[cutIndex + 1];
    if (!previewUsesFade(outgoing, incoming)) return;
    if (outgoing.transition != null &&
        NativeVideoEngine.supports(outgoing.transition)) {
      return;
    }

    if (_auxPrewarmedCutIndex == cutIndex) return;

    final gen = ++_auxPrewarmGen;
    await _ensureAuxController();
    if (!mounted || gen != _auxPrewarmGen) return;

    final aux = _auxController;
    if (aux == null || !aux.value.isInitialized) return;

    try {
      await aux.pause();
      await aux.setVolume(0);
      await aux.seekTo(incoming.start);
    } catch (_) {
      return;
    }

    final deadline = DateTime.now().add(const Duration(milliseconds: 200));
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || gen != _auxPrewarmGen) return;
      final drift =
          (aux.value.position - incoming.start).inMilliseconds.abs();
      if (drift <= 50 && !aux.value.isBuffering) break;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!mounted || gen != _auxPrewarmGen) return;
    _auxPrewarmedCutIndex = cutIndex;
  }

  Future<void> _startFlutterFadePreview(
    PreviewFadeWindow fade, {
    required bool entering,
  }) async {
    await _driveFadePreview(fade);
    if (!mounted || _fadeHandoffInFlight) return;
    if (_activeFade?.afterIndex != fade.afterIndex) return;

    final main = _controller;
    if (main == null) return;

    if (main.value.isPlaying && _fadeWallClockStart == null) {
      _beginFadeWallClock(entering ? fade.t : (_fadeProgress ?? fade.t));
    }
    _setFadeProgress(fade.t, playing: main.value.isPlaying);
  }

  void _syncNativeSpatialSeek(double t) {
    if (!_spatialPreviewActive || !NativeVideoEngine.instance.isActive) return;
    final active = _activeFade;
    if (active == null) return;
    final ms = (t.clamp(0.0, 1.0) * active.td.inMilliseconds).round();
    final target = Duration(milliseconds: ms);
    if ((NativeVideoEngine.instance.position - target).inMilliseconds.abs() > 40) {
      unawaited(NativeVideoEngine.instance.seek(target));
    }
  }

  Future<void> _showSpatialPreviewAt(
    PreviewFadeWindow fade, {
    required bool playing,
  }) async {
    final project = _project;
    final main = _controller;
    final transition = fade.outgoing.transition;
    if (project == null || main == null || transition == null) return;
    if (!NativeVideoEngine.supports(transition)) {
      unawaited(_startFlutterFadePreview(fade, entering: true));
      return;
    }

    final gen = ++_spatialPreviewGen;
    _nativePrewarmGen++;
    _fadeAnchoredAfterIndex = fade.afterIndex;
    _activeFade = fade;
    _spatialFrameReady = false;

    final prewarmed = _nativePrewarmedCutIndex == fade.afterIndex &&
        NativeVideoEngine.instance.isActive;
    int? textureId = prewarmed ? NativeVideoEngine.instance.textureId : null;

    if (!prewarmed) {
      textureId = await NativeVideoEngine.instance.prepareTransition(
        sourcePath: project.sourcePath,
        outgoing: fade.outgoing,
        incoming: fade.incoming,
        transition: transition,
      );
    }
    if (!mounted || gen != _spatialPreviewGen) return;

    if (textureId == null) {
      await _tearDownSpatialPreview();
      unawaited(_startFlutterFadePreview(fade, entering: true));
      return;
    }

    final prerollPos = Duration(
      milliseconds: (fade.t * fade.td.inMilliseconds).round(),
    );
    if (!NativeVideoEngine.instance.hasFrame ||
        prerollPos > Duration.zero) {
      final ready = await NativeVideoEngine.instance.preroll(prerollPos);
      if (!mounted || gen != _spatialPreviewGen) return;
      if (!ready) {
        await _tearDownSpatialPreview();
        unawaited(_startFlutterFadePreview(fade, entering: true));
        return;
      }
    }

    _nativePrewarmedCutIndex = null;
    _spatialTextureId = textureId;
    _spatialFrameReady = true;
    _spatialPreviewActive = true;
    _spatialPositionSub?.cancel();
    _spatialPlayingSub?.cancel();
    _spatialPositionSub =
        NativeVideoEngine.instance.positionStream.listen(_onNativeSpatialPosition);
    _spatialPlayingSub =
        NativeVideoEngine.instance.playingStream.listen((_) {
      if (mounted) setState(() {});
    });

    try {
      await main.pause();
      await main.setVolume(0);
      await _auxController?.pause();
      await _auxController?.setVolume(0);
    } catch (_) {}

    final pos = Duration(
      milliseconds: (fade.t * fade.td.inMilliseconds).round(),
    );
    if (playing) {
      await NativeVideoEngine.instance.play();
      _beginFadeWallClock(fade.t);
    } else {
      await NativeVideoEngine.instance.seek(pos);
    }
    _setFadeProgress(fade.t, playing: playing);
    if (mounted) setState(() {});
  }

  void _onNativeSpatialPosition(Duration position) {
    final active = _activeFade;
    if (!_spatialPreviewActive || active == null || !mounted) return;
    final td = active.td;
    if (td <= Duration.zero) return;

    final t = (position.inMilliseconds / td.inMilliseconds).clamp(0.0, 1.0);
    _activeFade = PreviewFadeWindow(
      afterIndex: active.afterIndex,
      t: t,
      outgoing: active.outgoing,
      incoming: active.incoming,
      td: active.td,
    );
    _setFadeProgress(t, playing: NativeVideoEngine.instance.isPlaying);

    final previewUntil = _transitionPreviewUntil;
    if (previewUntil != null &&
        position >= td - const Duration(milliseconds: 50)) {
      _transitionPreviewUntil = null;
      unawaited(NativeVideoEngine.instance.pause());
      unawaited(_syncMusicPlayback());
    }

    if (position >= td - const Duration(milliseconds: 50)) {
      if (!_fadeHandoffInFlight) {
        unawaited(_completeSpatialHandoff(active));
      }
    }
    setState(() {});
  }

  Future<void> _completeSpatialHandoff(PreviewFadeWindow done) async {
    if (_fadeHandoffInFlight) return;
    _fadeHandoffInFlight = true;
    try {
      final main = _controller;
      if (main == null) return;

      final wasPlaying =
          NativeVideoEngine.instance.isPlaying || main.value.isPlaying;

      await _tearDownSpatialPreview();

      final handoff = done.incoming.start + done.td;
      final target =
          handoff > done.incoming.end ? done.incoming.end : handoff;
      await main.seekTo(target);

      _activeFade = null;
      _clearFadeProgress();
      _fadeAnchoredAfterIndex = null;
      if (mounted) setState(() {});

      if (wasPlaying) {
        await main.play();
      }
      _syncVideoAudioVolume();
      unawaited(_syncMusicPlayback());
    } finally {
      _fadeHandoffInFlight = false;
    }
  }

  Future<void> _tearDownSpatialPreview({bool keepGen = false}) async {
    if (!keepGen) {
      _spatialPreviewGen++;
    }
    _spatialPreviewActive = false;
    _spatialTextureId = null;
    _spatialFrameReady = false;
    _nativePrewarmedCutIndex = null;
    await _spatialPositionSub?.cancel();
    await _spatialPlayingSub?.cancel();
    _spatialPositionSub = null;
    _spatialPlayingSub = null;
    await NativeVideoEngine.instance.dispose();
  }

  void _clearFadeProgress() {
    _fadeProgress = null;
    _fadeProgressPeak = 0;
    _fadeWallClockStart = null;
    _fadeWallClockStartT = 0;
  }

  void _beginFadeWallClock(double t) {
    _fadeWallClockStart = DateTime.now();
    _fadeWallClockStartT = t.clamp(0.0, 1.0);
    _fadeProgressPeak = _fadeWallClockStartT;
  }

  Future<void> _ensureAuxController() async {
    final project = _project;
    if (project == null) return;
    if (_slotAux != null && _slotAux!.value.isInitialized) return;

    final aux = VideoPlayerController.file(File(project.sourcePath));
    await aux.initialize();
    aux.setLooping(false);
    await aux.setVolume(0);
    if (!mounted) {
      await aux.dispose();
      return;
    }
    final previous = _slotAux;
    _slotAux = aux;
    await previous?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _driveFadePreview(PreviewFadeWindow fade) async {
    // Do NOT bump _fadeSyncGen here — every tick used to cancel in-flight
    // seeks and made the incoming layer hitch / jump backward.
    final gen = _fadeSyncGen;
    final main = _controller;
    if (main == null || _fadeHandoffInFlight) return;

    await _ensureAuxController();
    if (!mounted || gen != _fadeSyncGen) return;
    final aux = _auxController;
    if (aux == null || !aux.value.isInitialized) return;

    if (_fadeAnchoredAfterIndex != fade.afterIndex) {
      _fadeAnchoredAfterIndex = fade.afterIndex;
      final prewarmed = _auxPrewarmedCutIndex == fade.afterIndex;
      if (!prewarmed) {
        try {
          await aux.pause();
        } catch (_) {}
        if (!mounted || gen != _fadeSyncGen) return;
        await aux.seekTo(fade.incoming.start);
        if (!mounted || gen != _fadeSyncGen) return;
        final deadline = DateTime.now().add(const Duration(milliseconds: 200));
        while (DateTime.now().isBefore(deadline)) {
          if (!mounted || gen != _fadeSyncGen) return;
          final drift =
              (aux.value.position - fade.incoming.start).inMilliseconds.abs();
          if (drift <= 50 && !aux.value.isBuffering) break;
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        if (!mounted || gen != _fadeSyncGen) return;
      } else {
        try {
          await aux.pause();
        } catch (_) {}
        if (!mounted || gen != _fadeSyncGen) return;
      }
      _auxPrewarmedCutIndex = null;
      if (main.value.isPlaying) {
        await aux.play();
      }
    } else if (main.value.isPlaying) {
      if (!aux.value.isPlaying) await aux.play();
    } else if (aux.value.isPlaying) {
      await aux.pause();
    }
    if (!mounted || gen != _fadeSyncGen) return;

    _setFadeProgress(fade.t, playing: main.value.isPlaying);
  }

  /// Finish a dual-layer preview without seeking the visible stream.
  ///
  /// Seeking the main player to match aux lands on keyframes and causes the
  /// visible "frame jump". Instead we promote the already-correct aux player
  /// to be the primary controller. Physical VideoPlayer slots stay mounted in
  /// a fixed Stack order ([StableDualSlotPreview]) so handoff only flips roles
  /// and opacities — no remount of the visible surface.
  Future<void> _completeFadeHandoff(PreviewFadeWindow done) async {
    if (_fadeHandoffInFlight) return;
    _fadeHandoffInFlight = true;
    final gen = ++_fadeSyncGen;
    final main = _controller;
    final aux = _auxController;

    try {
      if (main == null) return;

      // Fallback: no aux → hard seek (should be rare).
      if (aux == null || !aux.value.isInitialized) {
        final handoff = done.incoming.start + done.td;
        await main.seekTo(
          handoff > done.incoming.end ? done.incoming.end : handoff,
        );
        _activeFade = null;
        _clearFadeProgress();
        _fadeAnchoredAfterIndex = null;
        if (mounted) setState(() {});
        return;
      }

      final wasPlaying = main.value.isPlaying ||
          aux.value.isPlaying ||
          NativeVideoEngine.instance.isPlaying;

      await _tearDownSpatialPreview();

      // Promote aux in the same frame we leave the blend. At t=1 the incoming
      // slot is already fully visible; after the flip that same physical slot
      // becomes the idle primary (opacity 1) — no seek, no tree teardown.
      main.removeListener(_onVideoTick);
      _slotsSwapped = !_slotsSwapped;
      _controller!.addListener(_onVideoTick);

      _activeFade = null;
      _clearFadeProgress();
      _fadeAnchoredAfterIndex = null;
      if (mounted) setState(() {});

      try {
        await _auxController?.setVolume(0);
        await _auxController?.pause();
      } catch (_) {}
      if (!mounted || gen != _fadeSyncGen) return;

      if (wasPlaying) {
        if (!_controller!.value.isPlaying) {
          await _controller!.play();
        }
      } else if (_controller!.value.isPlaying) {
        await _controller!.pause();
      }

      _syncVideoAudioVolume();
      unawaited(_syncMusicPlayback());
    } finally {
      _fadeHandoffInFlight = false;
    }
  }

  Future<void> _tearDownFadePreview() async {
    _fadeSyncGen++;
    _fadeHandoffInFlight = false;
    _activeFade = null;
    _clearFadeProgress();
    _fadeAnchoredAfterIndex = null;
    _auxPrewarmedCutIndex = null;
    _auxPrewarmGen++;
    _nativePrewarmGen++;
    await _tearDownSpatialPreview();
    final aux = _auxController;
    if (aux != null && aux.value.isInitialized) {
      try {
        await aux.pause();
        await aux.setVolume(0);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Widget _buildPreviewVideoChild(VideoPlayerController _) {
    if (_nativeTimelineActive &&
        NativeVideoEngine.instance.isTimelineMode &&
        NativeVideoEngine.instance.hasFrame) {
      return NativeVideoEngine.instance.buildPreview();
    }
    if (_spatialPreviewActive &&
        _spatialTextureId != null &&
        _spatialFrameReady) {
      return NativeVideoEngine.instance.buildPreview();
    }

    final slotMain = _slotMain;
    final slotAux = _slotAux;

    // Physical slots keep stable GlobalKeys forever. Roles flip via
    // [_slotsSwapped] so platform views are never disposed mid-handoff.
    if (slotMain == null) {
      return const SizedBox.shrink();
    }
    if (slotAux == null || !slotAux.value.isInitialized) {
      return VideoPlayer(slotMain, key: _slotMainKey);
    }

    final progress = _fadeProgress;
    final active = _activeFade;
    final plan = active == null
        ? null
        : TransitionEngine.instance.plan(active.outgoing.transition);

    return StableDualSlotPreview(
      slotMain: SizedBox.expand(
        child: VideoPlayer(slotMain, key: _slotMainKey),
      ),
      slotAux: SizedBox.expand(child: VideoPlayer(slotAux, key: _slotAuxKey)),
      slotsSwapped: _slotsSwapped,
      t: progress,
      plan: plan,
    );
  }

  Future<void> _loadSourceAudioWaveform(String sourcePath) async {
    final hasAudio = await _probe.hasAudioStream(sourcePath);
    if (!mounted) return;
    if (!hasAudio) {
      setState(() {
        _hasSourceAudio = false;
        _sourceAudioWaveform = const [];
      });
      return;
    }

    final wave = await AudioWaveformService.instance.waveformForFile(
      sourcePath,
    );
    if (!mounted) return;
    setState(() {
      _hasSourceAudio = true;
      _sourceAudioWaveform = wave?.peaks ?? const [];
    });
  }

  void _syncVideoAudioVolume() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;
    if (_spatialPreviewActive && !_nativeTimelineActive) {
      controller.setVolume(0);
      _auxController?.setVolume(0);
      return;
    }
    if (!_hasSourceAudio) {
      controller.setVolume(0);
      _auxController?.setVolume(0);
      return;
    }
    // Native timeline: VideoPlayer is display-fallback only — always silent.
    if (_nativeTimelineActive) {
      controller.setVolume(0);
      _auxController?.setVolume(0);
      return;
    }
    final playhead = _playhead;
    final fade = previewFadeAt(project.segments, playhead);
    if (fade != null) {
      final outLocal = playhead - fade.outgoing.start;
      final inLocal = fade.auxSourceTime - fade.incoming.start;
      final outVol = fade.outgoing.volumeAt(outLocal);
      final inVol = fade.incoming.volumeAt(inLocal);
      controller.setVolume(outVol * (1.0 - fade.t));
      _auxController?.setVolume(inVol * fade.t);
      return;
    }
    _auxController?.setVolume(0);

    ClipSegment? segment;
    for (final candidate in project.segments) {
      if (playhead >= candidate.start && playhead < candidate.end) {
        segment = candidate;
        break;
      }
    }
    if (segment == null) {
      controller.setVolume(0);
      return;
    }
    final local = playhead - segment.start;
    controller.setVolume(segment.volumeAt(local));
  }

  void _onVideoTick() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null || !mounted) return;

    // Native composition owns playback — VideoPlayer tick is idle.
    if (_nativeTimelineActive) {
      setState(() {});
      return;
    }

    final pos = controller.value.position;
    final scrub = _scrubPlayhead;
    if (scrub != null) {
      // User scrub owns the playhead until play is pressed. Transition preview
      // clears scrub before play(); do not pause-loop here during that window.
      if (_transitionPreviewUntil != null) {
        _scrubPlayhead = null;
      } else {
        if (controller.value.isPlaying) {
          unawaited(controller.pause());
          unawaited(_auxController?.pause() ?? Future<void>.value());
          unawaited(_syncMusicPlayback());
        }
        setState(() {});
        return;
      }
    }

    // Transition picker preview: play only through the applied effect window.
    final previewUntil = _transitionPreviewUntil;
    if (previewUntil != null && pos >= previewUntil) {
      _transitionPreviewUntil = null;
      controller.pause();
      unawaited(_auxController?.pause() ?? Future<void>.value());
      unawaited(_syncMusicPlayback());
    }

    if (pos >= project.trim.end) {
      controller.pause();
      controller.seekTo(project.trim.end);
    }
    _advancePlaybackPastGaps();
    _syncVideoAudioVolume();
    unawaited(_syncMusicOnTick());
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    final project = _project;
    if (project != null) {
      unawaited(_projectStorage.save(project));
    }
    _disposeFilmstrip();
    _nativeTimelineRebuildDebounce?.cancel();
    _nativeTimelineGen++;
    unawaited(_nativeTimelinePosSub?.cancel() ?? Future<void>.value());
    unawaited(_nativeTimelinePlayingSub?.cancel() ?? Future<void>.value());
    _nativeTimelinePosSub = null;
    _nativeTimelinePlayingSub = null;
    _nativeTimelineActive = false;
    unawaited(NativeVideoEngine.instance.dispose());
    _slotMain?.removeListener(_onVideoTick);
    _slotAux?.removeListener(_onVideoTick);
    final main = _slotMain;
    final aux = _slotAux;
    _slotMain = null;
    _slotAux = null;
    unawaited(main?.dispose() ?? Future<void>.value());
    unawaited(aux?.dispose() ?? Future<void>.value());
    unawaited(_tearDownSpatialPreview());
    unawaited(_musicPlayer.dispose());
    _stopDockSnapAnim();
    _dockHeight.dispose();
    _previewMaximizeEdgeLit.dispose();
    super.dispose();
  }

  /// How far to shift the preview up so the editing text clears the keyboard.
  double _previewLiftForEditing({
    required double bodyH,
    required double previewSlotW,
    required double previewSlotH,
    required double keyboard,
    required TextOverlay overlay,
  }) {
    if (keyboard <= 0 || previewSlotH <= 0 || previewSlotW <= 0) return 0;

    const toolbarH = 52.0;
    const margin = 16.0;
    const previewPadTop = 4.0;

    final canvasW = previewSlotW;
    final canvasH = canvasW * 16 / 9;
    final scale = math.min(previewSlotW / canvasW, previewSlotH / canvasH);

    final box = overlayBoxForFrame(overlay, frameWidth: canvasW);
    final body = OverlayGeometry.bodyRect(
      previewW: canvasW,
      previewH: canvasH,
      box: box,
    );
    // FittedBox(alignment: topCenter) — scaled canvas sits at the slot top.
    final overlayBottomInBody = previewPadTop + body.bottom * scale;
    final clearBottom = bodyH - keyboard - toolbarH - margin;
    final overflow = overlayBottomInBody - clearBottom;
    if (overflow <= 0) return 0;
    return overflow;
  }

  TextOverlay? get _selectedOverlay {
    final id = _selectedOverlayId;
    if (id == null) return null;
    final project = _project;
    if (project == null) return null;
    for (final overlay in project.overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  TextOverlay? get _textStudioOverlay {
    final id = _textStudioOverlayId;
    if (id == null) return null;
    final project = _project;
    if (project == null) return null;
    for (final overlay in project.overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  TextOverlay? get _editingOverlay {
    final id = _editingOverlayId;
    if (id == null) return null;
    final project = _project;
    if (project == null) return null;
    for (final overlay in project.overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  bool get _inTextStudio => _textStudioOverlayId != null;

  void _seek(Duration position, {bool seekVideo = true}) {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    final maxScrub = projectMaxScrubSourceTime(
      segments: project.segments,
      sourceDuration: project.duration,
      musicTracks: project.musicTracks,
      overlays: project.overlays,
    );
    final clamped = clampDuration(position, Duration.zero, maxScrub);
    _scrubPlayhead = clamped;
    if (!seekVideo) {
      setState(() {});
      return;
    }

    if (_nativeTimelineActive && NativeVideoEngine.instance.isTimelineMode) {
      final composition = sourceTimeToExportTime(
            project.segments,
            clamped,
          ) ??
          Duration.zero;
      final maxComp = totalKeptDuration(project.segments);
      final target = clampDuration(composition, Duration.zero, maxComp);
      unawaited(_scrubNativeTimeline(target));
      setState(() {});
      return;
    }

    // Scrubbing while playing used to fight the decoder every tick (clear scrub
    // → play continues → seek again) and the play/pause icon thrashed.
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
      unawaited(_auxController?.pause() ?? Future<void>.value());
    }
    final fade = previewFadeAt(project.segments, clamped);
    if (fade != null &&
        NativeVideoEngine.supports(fade.outgoing.transition)) {
      _scrubPlayhead = clamped;
      unawaited(
        _showSpatialPreviewAt(fade, playing: false).then((_) {
          controller.seekTo(clampDuration(clamped, Duration.zero, project.duration));
          unawaited(_syncMusicPlayback());
          _syncVideoAudioVolume();
        }),
      );
      setState(() {});
      return;
    }

    unawaited(_tearDownFadePreview());
    final videoSeek = clampDuration(clamped, Duration.zero, project.duration);
    controller.seekTo(videoSeek);
    unawaited(_syncMusicPlayback());
    _syncVideoAudioVolume();
    setState(() {});
  }

  /// Pause first (awaited), then coalesce video prerolls to the latest scrub target.
  Future<void> _scrubNativeTimeline(Duration target) async {
    if (NativeVideoEngine.instance.isPlaying) {
      await NativeVideoEngine.instance.pause();
      if (!mounted) return;
    }
    await _enqueueNativeScrub(target);
  }

  /// Coalesce drag seeks so only the latest target runs; never stack prerolls.
  Future<void> _enqueueNativeScrub(Duration target) async {
    _pendingNativeScrub = target;
    if (_nativeScrubInFlight) return;
    _nativeScrubInFlight = true;
    try {
      while (_pendingNativeScrub != null) {
        final next = _pendingNativeScrub!;
        _pendingNativeScrub = null;
        await NativeVideoEngine.instance
            .preroll(next)
            .timeout(const Duration(milliseconds: 900), onTimeout: () => true);
        if (!mounted) return;
        unawaited(_syncMusicPlayback());
        setState(() {});
      }
    } finally {
      _nativeScrubInFlight = false;
      final again = _pendingNativeScrub;
      if (again != null && mounted) {
        unawaited(_enqueueNativeScrub(again));
      }
    }
  }

  /// While dragging a clip edge, show that edge's frame without moving the
  /// centre playhead (so the handle stays under the finger).
  void _onEdgeFramePreview(Duration? sourceTime) {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    if (sourceTime == null) {
      _edgeFramePreviewActive = false;
      _lastEdgePreviewSeek = null;
      return;
    }

    if (!_edgeFramePreviewActive) {
      _edgeFramePreviewActive = true;
      // Freeze the timeline on the current centre; only the decoder moves.
      _scrubPlayhead = _playhead;
      if (controller.value.isPlaying) {
        unawaited(controller.pause());
        unawaited(_syncMusicPlayback());
      }
      unawaited(_tearDownFadePreview());
    }

    final videoSeek = clampDuration(
      sourceTime,
      Duration.zero,
      project.duration,
    );
    if (_lastEdgePreviewSeek != null &&
        (videoSeek - _lastEdgePreviewSeek!).inMilliseconds.abs() < 16) {
      return;
    }
    _lastEdgePreviewSeek = videoSeek;
    unawaited(controller.seekTo(videoSeek));
  }

  /// audioplayers: [AudioPlayer.seek] never completes while stopped (30s TimeoutException).
  Future<void> _musicSafe(Future<void> Function() op) async {
    try {
      await op().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Ignore — a later sync recovers after reload.
    } catch (_) {
      // Transient native player failures while scrubbing.
    }
  }

  Future<void> _syncMusicPlayback() async {
    final gen = ++_musicSyncGen;
    final project = _project;
    final controller = _controller;
    if (project == null || controller == null) {
      _syncedMusicId = null;
      await _musicSafe(_musicPlayer.pause);
      return;
    }

    final playhead = _playhead;
    final music = musicClipAtTime(project.musicTracks, playhead);
    if (music == null) {
      _syncedMusicId = null;
      // Prefer pause over stop — seek hangs forever after stop (audioplayers).
      await _musicSafe(_musicPlayer.pause);
      return;
    }

    final musicPath = MusicStorageService.musicPath(
      p.dirname(project.sourcePath),
      music,
    );
    if (!await File(musicPath).exists()) {
      if (gen != _musicSyncGen) return;
      _syncedMusicId = null;
      await _musicSafe(_musicPlayer.pause);
      return;
    }
    if (gen != _musicSyncGen) return;

    final needsReload =
        _syncedMusicId != music.id || _musicPlayer.state == PlayerState.stopped;
    if (needsReload) {
      await _musicSafe(
        () => _musicPlayer.setSource(DeviceFileSource(musicPath)),
      );
      if (gen != _musicSyncGen) return;
      _syncedMusicId = music.id;
    }

    final localOffset = playhead - music.timelineStart;
    await _musicSafe(() => _musicPlayer.setVolume(music.volumeAt(localOffset)));

    final musicPosition = music.sourceOffset + localOffset;
    if (musicPosition.isNegative || localOffset >= music.clipDuration) {
      await _musicSafe(_musicPlayer.pause);
      return;
    }

    await _musicSafe(() => _musicPlayer.seek(musicPosition));
    if (gen != _musicSyncGen) return;
    if (_isPreviewPlaying) {
      await _musicSafe(_musicPlayer.resume);
    } else {
      await _musicSafe(_musicPlayer.pause);
    }
  }

  /// During continuous playback: start/stop when entering/leaving a clip,
  /// update fade volume while inside — without reloading the file every tick.
  Future<void> _syncMusicOnTick() async {
    final project = _project;
    final controller = _controller;
    if (project == null || controller == null) return;

    final playhead = _playhead;
    final music = musicClipAtTime(project.musicTracks, playhead);
    if (music?.id != _syncedMusicId) {
      await _syncMusicPlayback();
      return;
    }
    if (music == null) return;

    final localOffset = playhead - music.timelineStart;
    await _musicPlayer.setVolume(music.volumeAt(localOffset));

    if (!_isPreviewPlaying) return;
    if (_musicPlayer.state != PlayerState.playing) {
      await _syncMusicPlayback();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    // Manual transport cancels a bounded transition preview.
    _transitionPreviewUntil = null;
    _scrubPlayhead = null;

    if (_nativeTimelineActive && NativeVideoEngine.instance.isTimelineMode) {
      _pendingNativeScrub = null;
      if (NativeVideoEngine.instance.isPlaying) {
        unawaited(NativeVideoEngine.instance.pause());
      } else {
        final maxComp = totalKeptDuration(project.segments);
        if (NativeVideoEngine.instance.position >= maxComp) {
          unawaited(
            NativeVideoEngine.instance.preroll(Duration.zero).then((_) {
              return NativeVideoEngine.instance.play();
            }),
          );
        } else {
          unawaited(NativeVideoEngine.instance.play());
        }
      }
      unawaited(_syncMusicPlayback());
      setState(() {});
      return;
    }

    if (controller.value.isPlaying) {
      controller.pause();
      unawaited(_auxController?.pause() ?? Future<void>.value());
    } else {
      if (controller.value.position >= project.trim.end ||
          controller.value.position < project.trim.start ||
          !isInKeptRegion(project.segments, controller.value.position)) {
        final start =
            segmentAt(project.segments, controller.value.position)?.start ??
            project.segments.first.start;
        controller.seekTo(start);
      }
      controller.play();
      final fade = previewFadeAt(project.segments, controller.value.position);
      if (fade != null) {
        unawaited(_driveFadePreview(fade));
      }
    }
    unawaited(_syncMusicPlayback());
    setState(() {});
  }

  /// Empty canvas tap: clear overlay chrome first; only then toggle playback.
  void _onPreviewBackgroundTap() {
    if (_editingOverlayId != null) {
      // Keep the text studio open; only end on-canvas editing / dismiss IME.
      _finishInlineEditing(
        _inTextStudio ? 'preview_outside_studio' : 'preview_outside',
      );
      return;
    }
    if (_inTextStudio) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (_selectedOverlayId != null) {
      OverlayEventLog.log('Editor', 'deselectOverlay', {
        'id': _selectedOverlayId,
      });
      setState(() => _selectedOverlayId = null);
      return;
    }
    if (_selectedMusicId != null) {
      setState(() => _selectedMusicId = null);
      return;
    }
    _togglePlay();
  }

  Future<void> _openMusicPicker() async {
    final project = _project;
    if (project == null || _exporting) return;

    final dir = await _projectStorage.projectDirectory(project.id);
    if (!mounted) return;

    final picked = await Navigator.of(context).push<ProjectMusic>(
      MaterialPageRoute(
        builder: (_) => MusicPickerScreen(
          projectDir: dir.path,
          current: project.musicTracks.isEmpty
              ? null
              : project.musicTracks.first,
        ),
      ),
    );
    if (picked == null) return;

    var clipDuration = picked.clipDuration;
    if (clipDuration < minMusicClipDuration) {
      clipDuration = minMusicClipDuration;
    }

    final clip = picked.copyWith(
      timelineStart: _playhead,
      clipDuration: clipDuration,
    );
    _mutate((p) {
      final placed = assignMusicLane(p.musicTracks, clip);
      p.musicTracks.add(placed);
      final compacted = compactMusicLanes(p.musicTracks);
      p.musicTracks
        ..clear()
        ..addAll(compacted);
      _selectedMusicId = placed.id;
      _selectedOverlayId = null;
      _selectedSegmentId = null;
    });
    unawaited(_ensureMusicWaveform(clip));
    await _syncMusicPlayback();
  }

  Future<void> _openTransitionPicker({int? cutIndex}) async {
    final project = _project;
    final l10n = AppLocalizations.of(context);
    if (project == null || _exporting) return;

    if (!hasVideoCuts(project.segments)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.transitionNeedsCuts)));
      return;
    }

    final sequenceTime = _sequenceTimeForSplit(project.segments, _playhead);
    final index =
        cutIndex ??
        _selectedTransitionAfterIndex ??
        nearestCutIndex(project.segments, sequenceTime);
    if (index < 0 || index >= project.segments.length - 1) {
      return;
    }

    // Open the studio immediately — don't block the first tap on pause/IME.
    _presentStudioDock(() {
      setState(() {
        _selectedTransitionAfterIndex = index;
        _selectedSegmentId = null;
        _selectedOverlayId = null;
        _selectedMusicId = null;
        _editingOverlayId = null;
        _textStudioOverlayId = null;
        _transitionStudioCutIndex = index;
      });
    });

    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  Future<void> _closeTransitionStudio(String source) async {
    final index = _transitionStudioCutIndex;
    OverlayEventLog.log('Editor', 'closeTransitionStudio', {
      'source': source,
      'cutIndex': index,
    });
    if (index == null) return;

    _transitionPreviewGen++;
    _transitionPreviewUntil = null;
    await _dismissStudioDock(() {
      if (!mounted) return;
      setState(() {
        _transitionStudioCutIndex = null;
      });
    });
    await _tearDownFadePreview();
    await _controller?.pause();
    await _auxController?.pause();
    unawaited(_syncMusicPlayback());
    if (mounted) setState(() {});
  }

  /// Reads default length from the server catalog (not a client constant).
  Duration _catalogDefaultTransitionDuration() {
    final catalog = TransitionCatalogService.instance.catalog;
    final item = catalog.byId('dissolve') ??
        (catalog.items.isNotEmpty ? catalog.items.first : null);
    final ms = item?.defaultDurationMs ?? 0;
    if (ms > 0) return Duration(milliseconds: ms);
    return Duration.zero;
  }

  void _applyTransitionAtCut(int index, AppliedTransition applied) {
    if (!mounted) return;
    _mutate((p) {
      if (index >= p.segments.length - 1) return;
      final segment = p.segments[index];
      if (applied.isNone) {
        p.segments[index] = segment.copyWith(clearTransition: true);
      } else {
        final clamped = clampedTransitionDuration(
          segment.copyWith(transition: applied),
          next: p.segments[index + 1],
        );
        p.segments[index] = segment.copyWith(
          transition: applied.copyWith(
            duration: clamped <= Duration.zero ? applied.duration : clamped,
          ),
        );
      }
    });
    setState(() {
      _selectedTransitionAfterIndex = applied.isNone ? null : index;
    });
    if (applied.isNone) {
      // Hard cut: drop any dual-layer preview and let playback continue
      // naturally. Seeking a "compare window" made the cut feel like a pause.
      _transitionPreviewGen++;
      _transitionPreviewUntil = null;
      _scrubPlayhead = null;
      unawaited(_tearDownFadePreview());
      return;
    }
    unawaited(_previewTransitionAtCut(index));
  }

  void _onTransitionDurationChanged(int index, Duration duration) {
    if (!mounted) return;
    final project = _project;
    if (project == null || index >= project.segments.length - 1) return;
    final segment = project.segments[index];
    if (!segment.hasTransition) return;
    final nextSeg = project.segments[index + 1];
    final tentative = segment.copyWith(
      transition: segment.transition!.copyWith(duration: duration),
    );
    final clamped = clampedTransitionDuration(tentative, next: nextSeg);
    project.segments[index] = segment.copyWith(
      transition: segment.transition!.copyWith(
        duration: clamped <= Duration.zero ? duration : clamped,
      ),
    );
    setState(() {});
    _scheduleSave();
  }

  void _onTransitionParametersChanged(
    int index,
    Map<String, double> parameters,
  ) {
    if (!mounted) return;
    final project = _project;
    if (project == null || index >= project.segments.length - 1) return;
    final segment = project.segments[index];
    if (!segment.hasTransition) return;
    project.segments[index] = segment.copyWith(
      transition: segment.transition!.copyWith(parameters: parameters),
    );
    _scheduleSave();
  }

  /// Seek to the cut and play only for the transition duration on the main timeline.
  ///
  /// Hard cuts (no effect / "None") still play a short window across the cut so
  /// the picker can A/B compare against an effect.
  Future<void> _previewTransitionAtCut(int cutIndex) async {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;
    if (cutIndex < 0 || cutIndex >= project.segments.length - 1) return;

    final gen = ++_transitionPreviewGen;
    final outgoing = project.segments[cutIndex];
    final incoming = project.segments[cutIndex + 1];
    final td = clampedTransitionDuration(outgoing, next: incoming);
    final hardCut = !outgoing.hasTransition || td <= Duration.zero;
    const hardCutPad = Duration(milliseconds: 500);
    final windowBefore = hardCut ? hardCutPad : td;
    final previewStart = outgoing.end - windowBefore;
    final clampedStart = previewStart < outgoing.start
        ? outgoing.start
        : previewStart;
    final previewUntil = hardCut
        ? (() {
            final end = incoming.start + hardCutPad;
            return end > incoming.end ? incoming.end : end;
          })()
        : clampedStart + td;

    _transitionPreviewUntil = previewUntil;
    // Seek with an optimistic playhead, then clear scrub so playback + dual-
    // layer fade can run. Leaving scrub set made _onVideoTick pause every tick.
    _scrubPlayhead = clampedStart;

    await _tearDownFadePreview();
    if (!mounted || gen != _transitionPreviewGen) return;

    if (!hardCut && NativeVideoEngine.supports(outgoing.transition)) {
      await controller.seekTo(clampedStart);
      if (!mounted || gen != _transitionPreviewGen) return;
      _scrubPlayhead = null;
      final fade = PreviewFadeWindow(
        afterIndex: cutIndex,
        t: 0,
        outgoing: outgoing,
        incoming: incoming,
        td: td,
      );
      await _showSpatialPreviewAt(fade, playing: true);
      if (!mounted || gen != _transitionPreviewGen) {
        await NativeVideoEngine.instance.pause();
        return;
      }
      unawaited(_syncMusicPlayback());
      _syncVideoAudioVolume();
      if (mounted) setState(() {});
      return;
    }

    if (!hardCut) {
      await _ensureAuxController();
      if (!mounted || gen != _transitionPreviewGen) return;
      final aux = _auxController;
      if (aux != null && aux.value.isInitialized) {
        try {
          await aux.pause();
          await aux.seekTo(incoming.start);
        } catch (_) {}
      }
    }
    if (!mounted || gen != _transitionPreviewGen) return;
    await controller.seekTo(clampedStart);
    if (!mounted || gen != _transitionPreviewGen) return;
    _scrubPlayhead = null;
    await controller.play();
    if (!mounted || gen != _transitionPreviewGen) {
      // Panel closed (or a newer preview started) while play() was in flight.
      await controller.pause();
      await _auxController?.pause();
      return;
    }
    unawaited(_syncMusicPlayback());
    _syncVideoAudioVolume();
    if (mounted) setState(() {});
  }

  Future<void> _loadMusicWaveforms(VideoProject project) async {
    for (final music in List<ProjectMusic>.from(project.musicTracks)) {
      await _ensureMusicMetadata(music);
      if (!mounted) return;
    }
  }

  /// Probe file length + waveform so trim extends at 1x (never time-stretches).
  Future<void> _ensureMusicMetadata(ProjectMusic music) async {
    final project = _project;
    if (project == null) return;
    final path = MusicStorageService.musicPath(
      p.dirname(project.sourcePath),
      music,
    );

    var fileDuration = music.fileDuration;
    if (fileDuration == null || fileDuration <= Duration.zero) {
      fileDuration = await _probe.readDuration(path);
    }

    if (!_musicWaveforms.containsKey(music.fileName)) {
      final wave = await AudioWaveformService.instance.waveformForFile(path);
      if (!mounted) return;
      if (wave != null) {
        if (fileDuration == null || fileDuration <= Duration.zero) {
          fileDuration = wave.duration;
        }
        setState(() => _musicWaveforms[music.fileName] = wave.peaks);
      }
    }

    if (!mounted) return;
    if (fileDuration == null || fileDuration <= Duration.zero) return;
    if (music.fileDuration == fileDuration) return;

    // Backfill duration without changing the visible trim window unless the
    // clip was longer than the real file (invalid).
    var clipDuration = music.clipDuration;
    final maxClip = fileDuration - music.sourceOffset;
    if (maxClip > Duration.zero && clipDuration > maxClip) {
      clipDuration = maxClip;
    }
    _patchMusicClipQuiet(
      music.copyWith(fileDuration: fileDuration, clipDuration: clipDuration),
    );
  }

  Future<void> _ensureMusicWaveform(ProjectMusic music) =>
      _ensureMusicMetadata(music);

  void _patchMusicClipQuiet(ProjectMusic next) {
    final project = _project;
    if (project == null) return;
    final i = project.musicTracks.indexWhere((m) => m.id == next.id);
    if (i < 0) return;
    setState(() => project.musicTracks[i] = next);
    _scheduleSave();
  }

  void _replaceMusicClip(ProjectMusic next) {
    _mutate((p) {
      final i = p.musicTracks.indexWhere((m) => m.id == next.id);
      if (i < 0) return;
      // Respect the lane the user dragged to when free; only reassign on conflict.
      final placed = assignMusicLane(
        p.musicTracks,
        next,
        preferLowestLane: false,
      );
      p.musicTracks[i] = placed;
      final compacted = compactMusicLanes(p.musicTracks);
      p.musicTracks
        ..clear()
        ..addAll(compacted);
    });
    unawaited(_syncMusicPlayback());
  }

  void _removeSelectedMusic() {
    final id = _selectedMusicId;
    if (id == null) return;
    _mutate((p) {
      p.musicTracks.removeWhere((m) => m.id == id);
      final compacted = compactMusicLanes(p.musicTracks);
      p.musicTracks
        ..clear()
        ..addAll(compacted);
      _selectedMusicId = null;
    });
    unawaited(_musicSafe(_musicPlayer.stop));
    _syncedMusicId = null;
  }

  /// CapCut-style text — opens the text studio on the Text (effects) tab.
  void _addTextOverlay() {
    _placeNewTextOverlay();
  }

  void _placeNewTextOverlay() {
    final project = _project;
    final controller = _controller;
    if (project == null || controller == null) return;

    if (controller.value.isPlaying) {
      unawaited(controller.pause());
    }

    final start = _textPlacementSourceTime(project);
    var end = start + const Duration(seconds: 3);
    if (end - start < minOverlayDuration) {
      end = start + minOverlayDuration;
    }

    final overlay = fitOverlayBoxToText(
      TextOverlay(text: '', start: start, end: end),
      emptyPlaceholder: context.l10n.textOverlayHint,
    );
    late TextOverlay placed;
    _mutate((p) {
      placed = assignOverlayLane(p.overlays, overlay, preferLowestLane: true);
      p.overlays.add(placed);
      final compacted = compactOverlayLanes(p.overlays);
      p.overlays
        ..clear()
        ..addAll(compacted);
      _selectedOverlayId = placed.id;
      _selectedSegmentId = null;
      _selectedMusicId = null;
      _selectedTransitionAfterIndex = null;
      _inlineEditSelectAll = false;
      _editingOverlayId = null;
      _transitionStudioCutIndex = null;
      // Studio id is set in [_presentStudioDock] so the sheet can rise.
    });
    // Keep the playhead on the new overlay so the selection box is visible.
    if (start != _playhead) {
      _seek(start);
    }
    _presentStudioDock(() {
      setState(() {
        _textStudioOverlayId = placed.id;
        _selectedOverlayId = placed.id;
      });
    });
  }

  /// Source time for a newly placed text clip — never a deleted video gap.
  Duration _textPlacementSourceTime(VideoProject project) {
    final t = _playhead;
    final segments = project.segments;
    if (segments.isEmpty) return t;
    if (isInKeptRegion(segments, t)) return t;
    // At / past the last frame (common when paused at EOF, or scrubbing music).
    if (t >= segments.last.end) return t;

    // Middle deleted gap: snap onto the previous kept frame.
    final prev = segmentEndingAtOrBefore(segments, t);
    if (prev != null) {
      final snapped = prev.end - const Duration(milliseconds: 1);
      return snapped < prev.start ? prev.start : snapped;
    }
    return segments.first.start;
  }

  void _openTextStudio(TextOverlay overlay) {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
    // Empty overlays may still be one-glyph wide from older fits — expand so
    // the placeholder stays horizontal under effects like Torn.
    final fitted = overlay.text.trim().isEmpty
        ? fitOverlayBoxToText(
            overlay,
            emptyPlaceholder: context.l10n.textOverlayHint,
          )
        : overlay;
    if (fitted.boxWidth != overlay.boxWidth ||
        fitted.boxHeight != overlay.boxHeight) {
      _updateOverlay(fitted);
    }
    _presentStudioDock(() {
      setState(() {
        _selectedOverlayId = fitted.id;
        _selectedSegmentId = null;
        _selectedMusicId = null;
        _selectedTransitionAfterIndex = null;
        _editingOverlayId = null;
        _transitionStudioCutIndex = null;
        _textStudioOverlayId = fitted.id;
      });
    });
  }

  void _closeTextStudio(String source) {
    final id = _textStudioOverlayId;
    OverlayEventLog.log('Editor', 'closeTextStudio', {
      'source': source,
      'studioId': id,
    });
    if (id == null) return;

    final project = _project;
    TextOverlay? overlay;
    if (project != null) {
      for (final o in project.overlays) {
        if (o.id == id) {
          overlay = o;
          break;
        }
      }
    }

    FocusManager.instance.primaryFocus?.unfocus();

    if (overlay != null && overlay.text.trim().isEmpty) {
      unawaited(
        _dismissStudioDock(() {
          if (!mounted) return;
          _deleteOverlay(id);
          setState(() {
            _textStudioOverlayId = null;
            _clearTextStudioHeightOverride();
            _editingOverlayId = null;
          });
        }),
      );
      return;
    }

    if (overlay != null && overlay.text != overlay.text.trim()) {
      _updateOverlay(overlay.copyWith(text: overlay.text.trim()));
    }

    unawaited(
      _dismissStudioDock(() {
        if (!mounted) return;
        setState(() {
          _textStudioOverlayId = null;
          _clearTextStudioHeightOverride();
          _editingOverlayId = null;
          _selectedOverlayId = source == 'preview_outside' ? null : id;
        });
      }),
    );
  }

  void _setClipRotation(double radians) {
    final project = _project;
    if (project == null) return;
    _mutate((p) => p.rotation = normalizeClipRotation(radians));
  }

  void _rotateClipQuarterTurn() {
    final project = _project;
    if (project == null) return;
    _setClipRotation(project.rotation + quarterTurn);
  }

  /// Copy of [overlay], nudged clear of the original so both stay grabbable.
  void _duplicateOverlay(TextOverlay overlay) {
    final project = _project;
    if (project == null) return;

    const nudge = 0.08;
    final copy = overlay.duplicate(
      offset: Offset(
        (overlay.offset.dx + nudge).clamp(-maxOverlayOffset, maxOverlayOffset),
        (overlay.offset.dy + nudge).clamp(-maxOverlayOffset, maxOverlayOffset),
      ),
    );

    OverlayEventLog.log('Editor', 'duplicateOverlay', {
      'from': overlay.id,
      'to': copy.id,
    });

    final index = project.overlays.indexWhere((o) => o.id == overlay.id);
    _mutate((p) {
      final placed = assignOverlayLane(p.overlays, copy);
      p.overlays.insert(index == -1 ? p.overlays.length : index + 1, placed);
      final compacted = compactOverlayLanes(p.overlays);
      p.overlays
        ..clear()
        ..addAll(compacted);
      _selectedOverlayId = placed.id;
      _editingOverlayId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _timelineKey.currentState?.revealSelectedOverlay();
    });
  }

  void _updateOverlay(TextOverlay updated) {
    final project = _project;
    if (project == null) return;

    final index = project.overlays.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    final fitted = fitOverlayBoxToText(updated);
    setState(() {
      final placed = assignOverlayLane(
        project.overlays,
        fitted,
        preferLowestLane: false,
      );
      project.overlays[index] = placed;
      final compacted = compactOverlayLanes(project.overlays);
      project.overlays
        ..clear()
        ..addAll(compacted);
    });
    _scheduleSave();
  }

  void _patchOverlay(
    String id,
    TextOverlay Function(TextOverlay current) patch,
  ) {
    final project = _project;
    if (project == null) return;

    final index = project.overlays.indexWhere((o) => o.id == id);
    if (index == -1) return;

    setState(() {
      final placed = assignOverlayLane(
        project.overlays,
        patch(project.overlays[index]),
        preferLowestLane: false,
      );
      project.overlays[index] = placed;
      final compacted = compactOverlayLanes(project.overlays);
      project.overlays
        ..clear()
        ..addAll(compacted);
    });
    _scheduleSave();
  }

  void _onOverlayTextChanged(TextOverlay overlay, String text) {
    if (_inlineEditSelectAll) {
      _inlineEditSelectAll = false;
    }
    _updateOverlay(overlay.copyWith(text: text));
  }

  void _finishInlineEditing(String source) {
    final id = _editingOverlayId;
    OverlayEventLog.log('Editor', 'finishInlineEditing', {
      'source': source,
      'editingId': id,
      'selectedId': _selectedOverlayId,
    });
    if (id == null) {
      OverlayEventLog.log('Editor', 'finishInlineEditingSkipped', {
        'source': source,
        'reason': 'not_editing',
      });
      return;
    }

    final project = _project;
    TextOverlay? overlay;
    if (project != null) {
      for (final o in project.overlays) {
        if (o.id == id) {
          overlay = o;
          break;
        }
      }
    }

    FocusManager.instance.primaryFocus?.unfocus();

    final placeholder = context.l10n.addText;
    final isUnusedSeed =
        overlay != null &&
        (overlay.text.trim().isEmpty || overlay.text == placeholder);

    if (isUnusedSeed) {
      // Text studio owns empty overlays until the sheet is confirmed/dismissed.
      // Deleting here would also tear down the effects panel with the IME.
      if (_inTextStudio) {
        OverlayEventLog.log('Editor', 'finishInlineEditingKeepStudioEmpty', {
          'source': source,
          'id': id,
        });
        setState(() {
          _editingOverlayId = null;
          _inlineEditSelectAll = false;
        });
        return;
      }
      OverlayEventLog.log('Editor', 'finishInlineEditingDeleteEmpty', {
        'source': source,
        'id': id,
      });
      _inlineEditSelectAll = false;
      _deleteOverlay(id);
      return;
    }

    if (overlay != null && overlay.text != overlay.text.trim()) {
      _updateOverlay(overlay.copyWith(text: overlay.text.trim()));
    }

    setState(() {
      _editingOverlayId = null;
      _inlineEditSelectAll = false;
      // Keep selection while the text studio stays open.
      if (!_inTextStudio) {
        _selectedOverlayId = source == 'preview_outside' ? null : id;
      }
    });
    OverlayEventLog.log('Editor', 'finishInlineEditingDone', {
      'source': source,
      'selectedId': id,
      'textLen': overlay?.text.length ?? 0,
    });
  }

  void _startInlineEditing(TextOverlay overlay) {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      controller.pause();
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      // On-canvas edit. If the studio is already open, keep it and retarget.
      _inlineEditSelectAll = false;
      if (_textStudioOverlayId != null) {
        _textStudioOverlayId = overlay.id;
      }
      _selectedOverlayId = overlay.id;
      _selectedSegmentId = null;
      _selectedMusicId = null;
      _selectedTransitionAfterIndex = null;
      _editingOverlayId = overlay.id;
    });
  }

  void _deleteOverlay(String id) {
    final project = _project;
    if (project == null) return;

    _mutate((p) {
      p.overlays.removeWhere((o) => o.id == id);
      final compacted = compactOverlayLanes(p.overlays);
      p.overlays
        ..clear()
        ..addAll(compacted);
      if (_selectedOverlayId == id) {
        _selectedOverlayId = null;
      }
      if (_editingOverlayId == id) {
        _editingOverlayId = null;
      }
      if (_textStudioOverlayId == id) {
        _textStudioOverlayId = null;
        _clearTextStudioHeightOverride();
      }
    });
  }

  void _deleteOverlayByOverlay(TextOverlay overlay) {
    unawaited(_confirmDeleteOverlay(overlay));
  }

  Future<void> _confirmDeleteOverlay(TextOverlay overlay) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.deleteText),
          content: Text(l10n.deleteTextConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.deleteText),
            ),
          ],
        );
      },
    );
    if (!mounted || confirmed != true) return;
    _deleteOverlay(overlay.id);
  }

  void _editSelectedOverlay() {
    final overlay = _selectedOverlay;
    if (overlay == null) return;
    _openTextStudio(overlay);
  }

  Future<void> _showExportOptions() async {
    final project = _project;
    if (project == null || _exporting) return;

    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text(l10n.saveToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_exportAndSave());
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(l10n.uploadShorts),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openUpload();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openUpload() {
    final project = _project;
    if (project == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => YouTubeUploadScreen(project: project),
      ),
    );
  }

  Future<void> _exportAndSave() async {
    final project = _project;
    if (project == null || _exporting) return;

    final l10n = context.l10n;
    final progress = ValueNotifier(0.0);
    setState(() => _exporting = true);

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExportProgressDialog(progressListenable: progress),
    );

    try {
      final quality = await _settings.getExportQualityProfile();
      final exportedPath = await _export.exportToFile(
        project,
        quality: quality,
        onProgress: (value) => progress.value = value,
      );
      await _exportSave.saveExportedVideo(exportedPath);

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.exportSuccess)));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();

      final message = e.toString();
      if (message.contains('save_cancelled')) {
        return;
      }
      if (message.contains('photos_permission_denied')) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.permissionPhotosDenied)));
        return;
      }
      if (message.contains('export_file_missing') ||
          message.contains('export_file_empty')) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.exportFailed)));
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.exportFailedWithMessage(message))),
      );
    } finally {
      progress.dispose();
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final project = _project;
    final controller = _controller;

    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.editorTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null || project == null || controller == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.editorTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage == 'project_not_found'
                  ? l10n.projectNotFound
                  : l10n.videoLoadError,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final aspectRatio = controller.value.aspectRatio == 0
        ? 9 / 16
        : controller.value.aspectRatio;
    final inTextStudio = _inTextStudio;
    final studioOverlay = _textStudioOverlay;
    final editingOverlay = _editingOverlay;

    return Scaffold(
      // Text studio is a Stack overlay — preview/timeline layout never reflows.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(l10n.editorTitle),
        actions: [
          if (inTextStudio)
            TextButton(
              onPressed: () => _closeTextStudio('save_button'),
              child: Text(l10n.save),
            )
          else ...[
            IconButton(
              onPressed: _history.canUndo ? _undo : null,
              icon: const Icon(Icons.undo),
              tooltip: l10n.undo,
            ),
            IconButton(
              onPressed: _history.canRedo ? _redo : null,
              icon: const Icon(Icons.redo),
              tooltip: l10n.redo,
            ),
            IconButton(
              onPressed: _exporting ? null : _showExportOptions,
              icon: const Icon(Icons.upload_outlined),
              tooltip: l10n.export,
            ),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, bodyConstraints) {
          final metrics = EditorSheetMetrics.of(context);
          final bodyH = bodyConstraints.maxHeight;
          final maxH = metrics.maxHeight.clamp(0.0, bodyH);
          final entryH = metrics.entryHeight.clamp(0.0, maxH);

          return Stack(
            key: _editorBodyKey,
            clipBehavior: Clip.none,
            children: [
              // Preview + timeline stay laid out exactly as usual — the text
              // sheet only paints on top and never reflows this column.
              Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final targetWidth = constraints.maxWidth;
                          final targetHeight = targetWidth * 16 / 9;
                          final keyboard = MediaQueryData.fromView(
                            View.of(context),
                          ).viewInsets.bottom;
                          final lift = editingOverlay == null
                              ? 0.0
                              : _previewLiftForEditing(
                                  bodyH: bodyH,
                                  previewSlotW: constraints.maxWidth,
                                  previewSlotH: constraints.maxHeight,
                                  keyboard: keyboard,
                                  overlay: editingOverlay,
                                );
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: (e) {
                                  OverlayEventLog.log(
                                    'EditorShell',
                                    'pointerDown',
                                    {
                                      'global': e.position,
                                      'hasPreviewState':
                                          _previewKey.currentState != null,
                                    },
                                  );
                                  _previewKey.currentState?.handlePointerDown(
                                    e,
                                  );
                                },
                                onPointerMove: (e) => _previewKey.currentState
                                    ?.handlePointerMove(e),
                                onPointerUp: (e) => _previewKey.currentState
                                    ?.handlePointerUp(e.pointer),
                                onPointerCancel: (e) => _previewKey.currentState
                                    ?.handlePointerCancel(e.pointer),
                                child: SizedBox.expand(
                                  child: ClipRect(
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween<double>(end: lift),
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, value, child) {
                                        return Transform.translate(
                                          offset: Offset(0, -value),
                                          child: child,
                                        );
                                      },
                                      child: FittedBox(
                                        fit: BoxFit.contain,
                                        clipBehavior: Clip.none,
                                        alignment: Alignment.topCenter,
                                        child: OverflowSizedBox(
                                          width: targetWidth,
                                          height: targetHeight,
                                          child: VideoPreviewWithOverlays(
                                            key: _previewKey,
                                            videoAspectRatio: aspectRatio,
                                            videoChild: _buildPreviewVideoChild(
                                              controller,
                                            ),
                                            overlays: project.overlays,
                                            segments: project.segments,
                                            position: _playhead,
                                            isPlaying: _isPreviewPlaying,
                                            clipRotation: project.rotation,
                                            hostViewportSize: Size(
                                              constraints.maxWidth,
                                              constraints.maxHeight,
                                            ),
                                            selectedOverlayId:
                                                _selectedOverlayId,
                                            editingOverlayId: _editingOverlayId,
                                            selectAllOnEdit:
                                                _inlineEditSelectAll,
                                            textHint: l10n.textOverlayHint,
                                            onOverlaySelected: (overlay) {
                                              if (_editingOverlayId != null &&
                                                  _editingOverlayId !=
                                                      overlay.id) {
                                                _finishInlineEditing(
                                                  'select_other_overlay',
                                                );
                                              }
                                              setState(() {
                                                _selectedOverlayId = overlay.id;
                                                // Keep the studio open; retarget it.
                                                if (_textStudioOverlayId !=
                                                    null) {
                                                  _textStudioOverlayId =
                                                      overlay.id;
                                                }
                                              });
                                            },
                                            onRequestEdit: _startInlineEditing,
                                            onBackgroundTap:
                                                _onPreviewBackgroundTap,
                                            onOverlayTextChanged:
                                                _onOverlayTextChanged,
                                            onEditingComplete:
                                                _finishInlineEditing,
                                            onOverlayOffsetChanged:
                                                (overlay, offset) {
                                                  _patchOverlay(
                                                    overlay.id,
                                                    (current) =>
                                                        current.copyWith(
                                                          offset: offset,
                                                        ),
                                                  );
                                                },
                                            onOverlayDeleted:
                                                _deleteOverlayByOverlay,
                                            onOverlayDuplicated:
                                                _duplicateOverlay,
                                            onOverlayEdit: (overlay) {
                                              setState(
                                                () => _selectedOverlayId =
                                                    overlay.id,
                                              );
                                              _editSelectedOverlay();
                                            },
                                            onOverlayBoxChanged:
                                                (overlay, transform) {
                                                  OverlayEventLog.log(
                                                    'Editor',
                                                    'overlayBoxChanged',
                                                    {
                                                      'id': overlay.id,
                                                      'width': transform.width
                                                          .toStringAsFixed(1),
                                                      'height': transform.height
                                                          .toStringAsFixed(1),
                                                      'font': transform.fontSize
                                                          .toStringAsFixed(1),
                                                      'offset':
                                                          transform.offset,
                                                      'rotation': transform
                                                          .rotation
                                                          .toStringAsFixed(3),
                                                    },
                                                  );
                                                  _patchOverlay(
                                                    overlay.id,
                                                    (
                                                      current,
                                                    ) => current.copyWith(
                                                      boxWidth: transform.width,
                                                      boxHeight:
                                                          transform.height,
                                                      fontSize:
                                                          transform.fontSize,
                                                      offset: transform.offset,
                                                      rotation:
                                                          transform.rotation,
                                                    ),
                                                  );
                                                },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (editingOverlay == null)
                                _buildPreviewDockDragEdge(
                                  zoneHeight: constraints.maxHeight * 0.2,
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  _buildDockResizeHandle(enabled: editingOverlay == null),
                  _buildBottomDock(
                    l10n: l10n,
                    project: project,
                    controller: controller,
                    inTextStudio: inTextStudio,
                    studioOverlay: studioOverlay,
                    bodyH: bodyH,
                    maxH: maxH,
                    entryH: entryH,
                    editingOverlay: editingOverlay,
                  ),
                ],
              ),
              // Keyboard tray — same strip for basic text and effect/template edit.
              if (editingOverlay != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Builder(
                    builder: (context) {
                      final keyboard = MediaQueryData.fromView(
                        View.of(context),
                      ).viewInsets.bottom;
                      // Anchor to the body bottom and fill the inset with the
                      // toolbar color. Pinning with `bottom: keyboard` alone
                      // left a dark strip when the inset and the visible
                      // keyboard top disagreed.
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BasicTextEditToolbar(
                            overlay: editingOverlay,
                            onChanged: _updateOverlay,
                          ),
                          ColoredBox(
                            color: BasicTextEditToolbar.barBackground,
                            child: SizedBox(
                              height: keyboard,
                              width: double.infinity,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Bottom dock: timeline chrome, text studio, or transition studio.
  ///
  /// Entry (`_dockHeight == null`) locks to 1/3 screen. Expanded uses an
  /// explicit height up to ~2/3 screen. `0` hides the dock (full video).
  Widget _buildBottomDock({
    required AppLocalizations l10n,
    required VideoProject project,
    required VideoPlayerController controller,
    required bool inTextStudio,
    required TextOverlay? studioOverlay,
    required double bodyH,
    required double maxH,
    required double entryH,
    required TextOverlay? editingOverlay,
  }) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ValueListenableBuilder<double?>(
      valueListenable: _dockHeight,
      builder: (context, dockH, _) {
        final h = (dockH ?? entryH).clamp(0.0, bodyH);
        if (h <= 0.5) {
          return const SizedBox(width: double.infinity, height: 0);
        }

        Widget wrapDock(Widget child) {
          return SizedBox(
            width: double.infinity,
            height: h,
            child: Padding(
              // Keep duration slider / action chips above the home indicator.
              padding: EdgeInsets.only(bottom: safeBottom),
              child: child,
            ),
          );
        }

        Widget slideInStudio(Key key, Widget child) {
          return TweenAnimationBuilder<double>(
            key: key,
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            builder: (context, t, painted) {
              return ClipRect(
                child: FractionalTranslation(
                  translation: Offset(0, t),
                  child: painted,
                ),
              );
            },
            child: child,
          );
        }

        final cutIndex = _transitionStudioCutIndex;
        final showTransition =
            cutIndex != null &&
            cutIndex >= 0 &&
            cutIndex < project.segments.length - 1;
        final showText = inTextStudio && studioOverlay != null;
        final showStudio = showText || showTransition;

        Widget? studio;
        if (showText) {
          studio = slideInStudio(
            ValueKey('text-studio-${studioOverlay.id}'),
            TapRegion(
              groupId: kBasicTextEditTapGroup,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
                child: TextStudioPanel(
                  overlay: studioOverlay,
                  onChanged: _updateOverlay,
                  onConfirm: () => _closeTextStudio('studio_confirm'),
                ),
              ),
            ),
          );
        } else if (showTransition) {
          final current = project.segments[cutIndex];
          final next = project.segments[cutIndex + 1];
          final maxTd = () {
            final maxMs = [
              current.duration.inMilliseconds,
              next.duration.inMilliseconds,
            ].reduce((a, b) => a < b ? a : b);
            final limit = maxMs > 100 ? maxMs - 50 : maxMs;
            return Duration(milliseconds: limit.clamp(50, 1 << 30));
          }();
          const minTd = Duration(milliseconds: 50);
          studio = slideInStudio(
            ValueKey('transition-studio-$cutIndex'),
            TransitionPickerPanel(
              key: ValueKey('transition-panel-$cutIndex'),
              initialSelectedId: current.transitionId ?? '',
              initialDuration: current.hasTransition
                  ? clampedTransitionDuration(current, next: next)
                  : _catalogDefaultTransitionDuration(),
              minDuration: minTd,
              maxDuration: maxTd < minTd ? minTd : maxTd,
              initialParameters: current.transition?.parameters ?? const {},
              onApplied: (applied) => _applyTransitionAtCut(cutIndex, applied),
              onDurationChanged: (duration) =>
                  _onTransitionDurationChanged(cutIndex, duration),
              onParametersChanged: (parameters) =>
                  _onTransitionParametersChanged(cutIndex, parameters),
              onConfirm: () =>
                  unawaited(_closeTransitionStudio('studio_confirm')),
            ),
          );
        }

        // Keep the timeline Element alive under studios so zoom/scroll survive.
        return wrapDock(
          Stack(
            fit: StackFit.expand,
            children: [
              Visibility(
                visible: !showStudio && editingOverlay == null,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: false,
                maintainInteractivity: false,
                child: IgnorePointer(
                  ignoring: showStudio || editingOverlay != null,
                  child: _buildCollapsibleChrome(
                    l10n: l10n,
                    project: project,
                    controller: controller,
                    isInlineEditing: _editingOverlayId != null,
                    dockHeight: dockH,
                    entryHeight: entryH,
                  ),
                ),
              ),
              if (studio != null) Positioned.fill(child: studio),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCollapsibleChrome({
    required AppLocalizations l10n,
    required VideoProject project,
    required VideoPlayerController controller,
    required bool isInlineEditing,
    required double? dockHeight,
    required double entryHeight,
  }) {
    final hidden = dockHeight != null && dockHeight <= 0.5;
    final height = dockHeight ?? entryHeight;

    Widget timeline = _buildTimeline(
      project: project,
      controller: controller,
      expandToFill: !hidden,
    );
    Widget actions = _buildBottomActions(l10n);

    if (isInlineEditing) {
      timeline = Listener(
        onPointerDown: (_) => _finishInlineEditing('timeline_pointer_down'),
        behavior: HitTestBehavior.translucent,
        child: timeline,
      );
      actions = Listener(
        onPointerDown: (_) => _finishInlineEditing('bottom_bar_pointer_down'),
        behavior: HitTestBehavior.translucent,
        child: actions,
      );
    }

    if (hidden) {
      return const SizedBox(width: double.infinity, height: 0);
    }

    // Fill the padded dock (bottom safe inset is applied by the parent).
    // Timeline fills leftover space; extra lanes scroll inside.
    final showActions = height >= 120;
    return SizedBox.expand(
      child: Column(
        children: [
          Expanded(child: timeline),
          if (showActions) ...[const SizedBox(height: 8), actions],
        ],
      ),
    );
  }

  Widget _buildTimeline({
    required VideoProject project,
    required VideoPlayerController controller,
    bool expandToFill = false,
  }) {
    return TimelineWidget(
      key: _timelineKey,
      duration: project.duration,
      trimStart: project.trim.start,
      trimEnd: project.trim.end,
      segments: project.segments,
      overlays: project.overlays,
      musicTracks: project.musicTracks,
      musicWaveforms: _musicWaveforms,
      sourceAudioWaveform: _sourceAudioWaveform,
      hasSourceAudio: _hasSourceAudio,
      filmstripFrames: _filmstripFrames,
      playhead: _timelinePlayhead,
      isPlaying: _isPreviewPlaying,
      onTogglePlay: _togglePlay,
      onHandleDragUpdate: _onChromeDragUpdate,
      onHandleDragEnd: _onChromeDragEnd,
      expandToFill: expandToFill,
      selectedOverlayId: _selectedOverlayId,
      selectedSegmentId: _selectedSegmentId,
      selectedMusicId: _selectedMusicId,
      selectedTransitionAfterIndex: _selectedTransitionAfterIndex,
      onPlayheadChanged: _seek,
      onPlayheadTimelineOnly: (position) => _seek(position, seekVideo: false),
      onEdgeFramePreview: _onEdgeFramePreview,
      onTrimStartChanged: (start) {
        setState(() {
          project.setTrimStart(start);
          _ensureHealthySegments(project);
        });
        _scheduleSave();
      },
      onTrimEndChanged: (end) {
        setState(() {
          project.setTrimEnd(end);
          _ensureHealthySegments(project);
        });
        _scheduleSave();
      },
      onOverlayChanged: _updateOverlay,
      onOverlaySelected: (overlay) {
        setState(() {
          _selectedOverlayId = overlay.id;
          _selectedSegmentId = null;
          _selectedMusicId = null;
          _selectedTransitionAfterIndex = null;
        });
      },
      onMusicChanged: _replaceMusicClip,
      onSegmentChanged: (segment) {
        _mutate((p) {
          final i = p.segments.indexWhere((s) => s.id == segment.id);
          if (i >= 0) p.segments[i] = segment;
        });
        _syncVideoAudioVolume();
      },
      onMusicSelected: (music) {
        setState(() {
          _selectedMusicId = music.id;
          _selectedOverlayId = null;
          _selectedSegmentId = null;
          _selectedTransitionAfterIndex = null;
        });
      },
      onSegmentSelected: (segment) {
        setState(() {
          _selectedSegmentId = segment.id;
          _selectedOverlayId = null;
          _selectedMusicId = null;
          _selectedTransitionAfterIndex = null;
        });
      },
      onTransitionSelected: (index) {
        setState(() {
          _selectedTransitionAfterIndex = index;
          if (index != null) {
            _selectedSegmentId = null;
            _selectedOverlayId = null;
            _selectedMusicId = null;
          }
        });
        if (index != null && !_exporting) {
          unawaited(_openTransitionPicker(cutIndex: index));
        }
      },
    );
  }

  Widget _buildBottomActions(AppLocalizations l10n) {
    return Padding(
      // Dock already clears the home indicator; keep a small gap only.
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  onPressed: _exporting ? null : _addTextOverlay,
                  icon: _TextAddIcon(enabled: !_exporting, sparkle: true),
                  tooltip: l10n.addText,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting ? null : _splitAtPlayhead,
                  icon: const Icon(Icons.content_cut),
                  tooltip: l10n.splitVideo,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed:
                      _exporting ||
                          _project == null ||
                          !hasVideoCuts(_project!.segments)
                      ? null
                      : _openTransitionPicker,
                  icon: const Icon(Icons.animation_outlined),
                  tooltip: l10n.transition,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed:
                      (_selectedSegmentId == null &&
                              _selectedMusicId == null &&
                              _selectedOverlayId == null) ||
                          _exporting
                      ? null
                      : () {
                          if (_selectedMusicId != null) {
                            _removeSelectedMusic();
                          } else if (_selectedOverlayId != null) {
                            _deleteOverlay(_selectedOverlayId!);
                          } else {
                            _deleteSelectedSegment();
                          }
                        },
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.deleteSegment,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting ? null : _openMusicPicker,
                  icon: const Icon(Icons.library_music_outlined),
                  tooltip: l10n.addMusic,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting ? null : _rotateClipQuarterTurn,
                  icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                  tooltip: l10n.rotateVideo,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-bar text affordance: plain **T+**, or template **T+** with ✨.
class _TextAddIcon extends StatelessWidget {
  const _TextAddIcon({required this.enabled, this.sparkle = false});

  final bool enabled;
  final bool sparkle;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white38;
    final accent = enabled
        ? const Color(0xFF4CC9F0)
        : const Color(0xFF4CC9F0).withValues(alpha: 0.4);

    return SizedBox(
      width: 26,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'T',
                    style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      letterSpacing: -0.5,
                    ),
                  ),
                  TextSpan(
                    text: '+',
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (sparkle) ...[
            Positioned(
              right: -1,
              top: -3,
              child: Icon(Icons.auto_awesome, size: 11, color: accent),
            ),
            Positioned(
              right: 8,
              top: -1,
              child: Icon(Icons.auto_awesome, size: 7, color: accent),
            ),
          ],
        ],
      ),
    );
  }
}
