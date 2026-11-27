import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/canvas_ratio.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/paywall_screen.dart';
import 'package:aveditor/services/effect_ad_unlock_service.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/widgets/premium_export_sheet.dart';
import 'package:aveditor/screens/export_share_screen.dart';
import 'package:aveditor/screens/music_picker_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/widgets/editor_onboarding_overlay.dart';
import 'package:aveditor/services/editor_history.dart';
import 'package:aveditor/services/audio_waveform_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/services/music_storage_service.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/video_import_service.dart';
import 'package:aveditor/services/voice_record_service.dart';
import 'package:aveditor/utils/platform_helper.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:aveditor/services/timeline_thumbnail_service.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:aveditor/utils/debug_agent_log.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/music_timeline_ops.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/widgets/canvas_ratio_sheet.dart';
import 'package:aveditor/widgets/convert_progress_view.dart';
import 'package:aveditor/widgets/basic_text_edit_toolbar.dart';
import 'package:aveditor/widgets/text_studio_panel.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:aveditor/widgets/giphy_sticker_picker_sheet.dart';
import 'package:aveditor/widgets/transition_picker_sheet.dart';
import 'package:aveditor/widgets/transition_preview_compositor.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/services/composition_segments.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.projectId, this.onReady});

  final String projectId;

  /// Fired once when the editor UI is ready to show (home can clear open progress).
  final VoidCallback? onReady;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Gap + always-visible resize affordance between preview and dock.
  static const _dockResizeHandleHeight = 35.0;

  /// Resize-strip fill; preview letterbox uses the same so the strip disappears.
  static const _previewChromeColor = Colors.black;

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

  /// Android HEVC / ProRes. The original file stays, and ffmpeg plays it.
  var _ffmpegPlayback = false;
  var _sourceAspect = 9 / 16;

  /// Wall-clock play through music/text after the last video frame.
  Timer? _sequenceTailTimer;
  DateTime? _sequenceTailAnchorAt;
  Duration? _sequenceTailAnchorPlayhead;
  var _sequenceTailPlaying = false;

  /// User wants transport to keep going (native EOF → audio/text black tail).
  var _wantPlayback = false;
  StreamSubscription<bool>? _timelinePlayingSub;

  bool get _transportPlaying {
    if (_sequenceTailPlaying) return true;
    if (NativeVideoEngine.instance.isTimelineActive) {
      return NativeVideoEngine.instance.isPlaying;
    }
    return _controller?.value.isPlaying ?? false;
  }

  /// Aux opacity while a fade is active; null when not fading.
  double? _fadeProgress;

  /// Highest blend progress seen for the current cut — decoder position can
  /// jitter backward a few ms and that made slide transforms tremble.
  double _fadeProgressPeak = 0;

  /// Wall-clock anchor so slide/push progress advances smoothly while playing
  /// instead of tracking noisy decoder timestamps.
  DateTime? _fadeWallClockStart;
  double _fadeWallClockStartT = 0;
  Timer? _fadeHoldTimer;
  var _outgoingHeld = false;
  var _fadeHoldShouldResume = false;

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

  /// Pause once the main playhead reaches this time (transition-length preview).
  Duration? _transitionPreviewUntil;
  Timer? _transitionPreviewTimer;
  var _transitionPreviewArmed = false;

  /// Source time where the current panel preview seeked. Used to ignore stale
  /// native position events still reporting the previous playhead (past until).
  Duration? _transitionPreviewWindowStart;

  /// True after we have seen a native sample inside the preview window.
  /// Until then, samples >= until are treated as stale and ignored.
  var _transitionPreviewSeekConfirmed = false;

  /// Bumped to cancel an in-flight [_previewTransitionAtCut] (e.g. panel close).
  int _transitionPreviewGen = 0;

  /// Cut index while the docked transition studio is open; null when closed.
  int? _transitionStudioCutIndex;

  /// Live source time for the current panel preview playhead.
  Duration? _panelPreviewSourcePos;

  /// Furthest source time in the *current* preview run only.
  /// Reset whenever a new item/duration preview starts — not across the
  /// whole studio session (a prior 3s finish must not outrank a new 1s pick).
  Duration? _panelPreviewFurthestPos;

  /// Seek target that wins over a zeroed native clock after panel preview.
  Duration? _pendingTimelineSeek;

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

  /// Docked Giphy sticker picker (same shell as transition / text studio).
  var _stickerStudioOpen = false;

  /// When set, picking a sticker replaces this overlay instead of adding one.
  String? _stickerReplaceOverlayId;

  bool _ready = false;
  double? _convertProgress;
  var _appendingMedia = false;
  var _exporting = false;

  /// True while catalog/entitlement refresh runs before the premium sheet.
  var _premiumGateBusy = false;
  double? _exportProgress;
  final _exportService = ExportService();
  final _appSettings = const AppSettingsService();
  final _import = VideoImportService();
  final _musicStorage = MusicStorageService();
  final _voiceRecorder = VoiceRecordService();

  /// Mic → start button → 3-2-1 → live take → stop.
  _VoiceRecordPhase _voicePhase = _VoiceRecordPhase.idle;
  Timer? _voiceCountdownTimer;
  Timer? _voiceTickTimer;
  int _voiceCountdown = 0;
  String? _voiceDraftId;
  Duration? _voiceTimelineStart;
  DateTime? _voiceStartedAt;
  var _voiceBusy = false;
  var _canvasRatioOpen = false;
  bool _applyingHistory = false;
  String? _errorMessage;

  /// Optimistic playhead while `seekTo` is in flight (avoids timeline jitter).
  Duration? _scrubPlayhead;

  /// True while a trim/resize edge drag is previewing frames without moving
  /// the centre playhead.
  bool _edgeFramePreviewActive = false;
  Duration? _lastEdgePreviewSeek;

  /// Coalesced mid-drag packed rebuild: only the latest drag state is applied,
  /// so in-flight prepares never flash a stale pack after a newer one.
  Duration? _pendingPackedEdgeSeek;
  bool _packedEdgeRebuildInFlight = false;

  final _projectStorage = const ProjectStorageService();
  final _history = EditorHistory();
  final _thumbnailService = const TimelineThumbnailService();
  final _probe = const VideoProbeService();
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();
  final _timelineKey = GlobalKey<TimelineWidgetState>();
  final _editorBodyKey = GlobalKey();
  final _onboardSplitKey = GlobalKey();
  final _onboardTextKey = GlobalKey();
  final _onboardTimelineKey = GlobalKey();
  final _onboardDockKey = GlobalKey();
  final _onboardTextTabKey = GlobalKey();
  final _onboardTextTemplatesTabKey = GlobalKey();
  final _textStudioPanelKey = GlobalKey<TextStudioPanelState>();
  var _coach = _EditorCoachKind.none;
  var _pendingSplitTransitionTip = false;
  var _pendingSplitReorderTip = false;
  var _pendingTextChromeTip = false;
  final _musicPlayer = AudioPlayer();

  /// Last music clip loaded into [_musicPlayer]; null when stopped.
  String? _syncedMusicId;
  int _musicSyncGen = 0;

  List<TimelineFilmstripFrame> _filmstripFrames = [];
  final Map<String, List<double>> _musicWaveforms = {};
  final Map<String, List<double>> _sourceAudioWaveforms = {};
  final Map<String, Duration> _sourceAudioDurations = {};
  bool _hasSourceAudio = false;

  Timer? _saveDebounce;

  /// Fast rebuild while resizing a clip hold so packed preview matches the
  /// centre playhead (save debounce alone is too slow / deferred mid-drag).
  Timer? _segmentLayoutRebuildDebounce;

  /// Bottom-dock height.
  ///
  /// - `null` → **entry / mid**: default dock (~0.45 screen)
  /// - `0` → full video (dock hidden)
  /// - `> 0` → explicit snap (compact / entry / max ~2/3) or live drag
  final ValueNotifier<double?> _dockHeight = ValueNotifier(null);
  AnimationController? _dockSnapAnim;
  Completer<void>? _dockAnimCompleter;
  double _dockAnimFrom = 0;
  double _dockAnimTo = 0;

  /// Bottom-of-preview drag strip: grow / shrink the dock vs the video.
  final ValueNotifier<bool> _previewMaximizeEdgeLit = ValueNotifier(false);
  int? _previewMaximizeEdgePointer;
  VelocityTracker? _previewMaximizeEdgeVelocity;

  void _logTimeline(String tag, {Duration? land, Duration? mapped}) {
    final engine = NativeVideoEngine.instance;
    final ctrl = _controller?.value.position;
    debugPrint(
      '[TL] $tag | '
      'playhead=${_playhead.inMilliseconds}ms '
      'timelinePlayhead=${_timelinePlayhead.inMilliseconds}ms '
      'scrub=${_scrubPlayhead?.inMilliseconds} '
      'panelPos=${_panelPreviewSourcePos?.inMilliseconds} '
      'furthest=${_panelPreviewFurthestPos?.inMilliseconds} '
      'pendingSeek=${_pendingTimelineSeek?.inMilliseconds} '
      'nativePos=${engine.position.inMilliseconds}ms '
      'nativeDur=${engine.duration.inMilliseconds}ms '
      'timelineActive=${engine.isTimelineActive} '
      'spatial=$_spatialPreviewActive '
      'fade=${_activeFade != null} '
      'ctrl=${ctrl?.inMilliseconds} '
      '${land != null ? 'land=${land.inMilliseconds}ms ' : ''}'
      '${mapped != null ? 'mapped=${mapped.inMilliseconds}ms ' : ''}'
      'studioCut=$_transitionStudioCutIndex',
    );
  }

  Duration get _playhead {
    if (_sequenceTailPlaying) {
      final anchorAt = _sequenceTailAnchorAt;
      final anchorHead = _sequenceTailAnchorPlayhead;
      if (anchorAt != null && anchorHead != null) {
        final advanced = anchorHead + DateTime.now().difference(anchorAt);
        final end = _sequenceDuration;
        if (advanced >= end) return end;
        return advanced;
      }
    }
    if (_scrubPlayhead != null) return _scrubPlayhead!;
    // Short panel preview clock is 0…td — map it onto the source cut window.
    if (_spatialPreviewActive) {
      final fade = _activeFade;
      if (fade != null && fade.td > Duration.zero) {
        // Short prepareTransition session is 0…td over [cut−⌊td/2⌋, cut+⌈td/2⌉).
        final start = fade.windowStart;
        final mapped = start + NativeVideoEngine.instance.position;
        var clamped = mapped;
        if (clamped < start) clamped = start;
        if (clamped > fade.windowEnd) clamped = fade.windowEnd;
        final panel = _panelPreviewSourcePos;
        // Monotonic: never snap UI back if a stale native sample reports 0.
        if (panel != null && panel > clamped) return panel;
        return clamped;
      }
      if (_panelPreviewSourcePos != null) return _panelPreviewSourcePos!;
    }
    if (NativeVideoEngine.instance.isTimelineActive) {
      // Native timeline is packed export time (duration-preserving A+B).
      return _nativePackedToSource(NativeVideoEngine.instance.position);
    }
    // Outgoing video is paused on its last frame. Keep the playhead moving
    // across the rest of the transition window.
    if (_outgoingHeld) {
      final fade = _activeFade;
      final t = _fadeProgress;
      if (fade != null && t != null) {
        final startMs = fade.windowStart.inMilliseconds;
        final spanMs = fade.windowEnd.inMilliseconds - startMs;
        return Duration(milliseconds: startMs + (spanMs * t).round());
      }
    }
    return _controller?.value.position ?? Duration.zero;
  }

  /// Multi-source: UI + native share the packed sequence clock.
  bool get _usesPackedPlayhead {
    final project = _project;
    return project != null && project.mediaAssets.isNotEmpty;
  }

  /// Video ∪ music ∪ text end (black pad past picture). Playback/export stop here.
  Duration get _sequenceDuration {
    final project = _project;
    if (project == null) return Duration.zero;
    return projectSequenceDuration(
      segments: project.segments,
      sourceDuration: project.duration,
      musicTracks: project.musicTracks,
      overlays: project.overlays,
    );
  }

  /// True when the playhead is past the last video frame (show black).
  bool get _playheadPastPicture {
    final project = _project;
    if (project == null || project.segments.isEmpty) return false;
    return _playhead >= exportTimelineDuration(project.segments);
  }

  /// Native timeline clock → UI playhead time.
  Duration _nativePackedToSource(Duration packed) {
    final project = _project;
    if (project == null || project.segments.isEmpty || _usesPackedPlayhead) {
      return packed;
    }
    return exportTimeToSourceTime(
      project.segments,
      packed,
      applyTransitions: true,
    );
  }

  /// UI playhead time → native timeline clock (seek / preroll).
  Duration _sourceToNativePacked(Duration source) {
    final project = _project;
    if (project == null || project.segments.isEmpty || _usesPackedPlayhead) {
      return source;
    }
    return sourceTimeToExportTime(
          project.segments,
          source,
          applyTransitions: true,
        ) ??
        source;
  }

  /// Timeline playhead during a dual-layer transition.
  ///
  /// Packed transition is centered on the cut: [C − ⌊td/2⌋, C + ⌈td/2⌉).
  /// Remap with [t] so the playhead advances continuously across the blend.
  Duration get _timelinePlayhead {
    final project = _project;
    final fade = _activeFade;
    if (project == null || fade == null || fade.td <= Duration.zero) {
      return _playhead;
    }
    // Panel short-session: source mapping is already in [_playhead].
    if (_spatialPreviewActive) return _playhead;
    final cut = cutExportTimeAfter(project.segments, fade.afterIndex);
    final half = transitionHalfMs(fade.td);
    final t = _fadeHandoffInFlight ? 1.0 : (_fadeProgress ?? fade.t);
    final traveledMs = (t * fade.td.inMilliseconds).round().clamp(0, 1 << 30);
    final sequenceTime =
        cut -
        Duration(milliseconds: half.before) +
        Duration(milliseconds: traveledMs);
    return exportTimeToSourceTime(
      project.segments,
      sequenceTime,
      applyTransitions: true,
    );
  }

  int _engineClaim = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engineClaim = NativeVideoEngine.instance.claim();
    AnalyticsService.instance.log('editor_open');
    // User opened the draft — drop pending abandon reminders.
    unawaited(RetentionNotificationService.instance.cancelDraftAbandon());
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

  /// Mid / initial dock (~0.45 of the screen).
  double _entryDockHeight() {
    final maxH = _maxDockHeight();
    if (!mounted) {
      return (800 * EditorSheetMetrics.entryFractionValue).clamp(0.0, maxH);
    }
    final metrics = EditorSheetMetrics.of(context);
    return metrics.entryHeight.clamp(0.0, maxH);
  }

  /// Compact dock between full-video and entry — video stays large.
  double _compactDockHeight() {
    final entry = _entryDockHeight();
    if (!mounted) {
      return (800 * EditorSheetMetrics.compactFractionValue).clamp(0.0, entry);
    }
    final metrics = EditorSheetMetrics.of(context);
    return metrics.compactHeight.clamp(0.0, entry);
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

  /// Show text / transition studio without collapsing timeline state.
  void _presentStudioDock(VoidCallback applyStudioState) {
    FocusManager.instance.primaryFocus?.unfocus();
    applyStudioState();
    // Collapsed dock (height 0) paints no studio — raise to entry so the
    // transition / text panel can actually appear.
    if (_dockHeightPx() < TransitionPickerPanel.headerHeight) {
      unawaited(_setDockHeight(null, animate: true));
    }
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

  /// Snap dock: hidden ↔ compact ↔ entry ↔ max (2/3).
  void _settleDockHeight({required double velocity}) {
    final current = _dockHeightPx();
    final entry = _entryDockHeight();
    final maxH = _maxDockHeight();
    final compact = _compactDockHeight();
    final target = snapDockHeight(
      current: current,
      velocity: velocity,
      stops: dockHeightStops(
        entryHeight: entry,
        maxHeight: maxH,
        compactHeight: compact,
      ),
      flingVelocity: _dockFlingVelocity,
    );
    if ((target - entry).abs() <= 8) {
      unawaited(_setDockHeight(null, animate: true));
    } else {
      unawaited(_setDockHeight(target, animate: true));
    }
  }

  void _onPreviewMaximizePointerDown(
    PointerDownEvent event, {
    bool yieldToOverlay = true,
  }) {
    // In-preview lower-fifth zone shares space with text — yield so dragging
    // text does not also resize the dock. The always-visible arrow strip below
    // the preview must never yield (oversized text used to steal it).
    if (yieldToOverlay &&
        _previewKey.currentState?.claimsOverlayPointer(event) == true) {
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
  /// Black bar height is fixed at every dock stage (incl. video-min / dock-max).
  /// Chevrons stay; only the grip shifts inside the bar. Home-indicator
  /// clearance when fully collapsed is transparent padding below the bar.
  Widget _buildDockResizeHandle({required bool enabled}) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ValueListenableBuilder<double?>(
      valueListenable: _dockHeight,
      builder: (context, dockH, _) {
        final maxH = _maxDockHeight();
        final atHidden = dockH != null && dockH <= 0.5;
        final atMax = dockH != null && dockH >= maxH - 24;
        final hint = atHidden
            ? _DockResizeHint.up
            : atMax
            ? _DockResizeHint.down
            : _DockResizeHint.both;

        // Painted black region — never grows with dock stage or chevrons.
        final bar = SizedBox(
          key: _onboardDockKey,
          height: _dockResizeHandleHeight,
          width: double.infinity,
          child: ClipRect(
            child: ValueListenableBuilder<bool>(
              valueListenable: _previewMaximizeEdgeLit,
              builder: (context, lit, _) {
                return ColoredBox(
                  color: _previewChromeColor,
                  child: Align(
                    // Keep bar height fixed; move the notch inside it.
                    alignment: atHidden
                        ? const Alignment(0, -0.35)
                        : atMax
                        ? const Alignment(0, 0.35)
                        : Alignment.center,
                    child: _DockResizeGrip(lit: lit, hint: hint),
                  ),
                );
              },
            ),
          ),
        );

        final strip = atHidden && safeBottom > 0
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  bar,
                  SizedBox(height: safeBottom),
                ],
              )
            : bar;

        if (!enabled) return strip;

        return Semantics(
          label: atHidden
              ? context.l10n.showTimeline
              : context.l10n.hideTimeline,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) =>
                _onPreviewMaximizePointerDown(e, yieldToOverlay: false),
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

  bool get _ownsEngine => NativeVideoEngine.instance.generation == _engineClaim;

  Future<void> _initVideo() async {
    try {
      await NativeVideoEngine.instance.release(_engineClaim);
      if (!mounted || !_ownsEngine) return;
      final stored = await _projectStorage.load(widget.projectId);
      if (stored == null) {
        if (!mounted) return;
        setState(() {
          _ready = true;
          _errorMessage = 'project_not_found';
        });
        widget.onReady?.call();
        return;
      }

      final playable = await _projectStorage.ensurePlayableSource(
        stored,
        onProgress: (value) {
          if (!mounted) return;
          final next = value.clamp(0.0, 1.0);
          final current = _convertProgress;
          if (current != null && (next - current).abs() < 0.01 && next < 1) {
            return;
          }
          setState(() => _convertProgress = next);
        },
      );
      final sourcePath = playable.sourcePath;
      // Probe the first *timeline* video so orphaned wide assets do not
      // lock Original canvas after the user wiped and re-imported clips.
      final probePath = playable.primaryVideoPath;
      VideoPlayerController? controller;
      var duration = playable.duration;
      var sourceAspect = 9 / 16;
      controller = await _openPlayableController(probePath);
      if (controller == null) {
        throw StateError('video open failed');
      }
      controller.setLooping(false);
      controller.addListener(_onVideoTick);
      if (duration == Duration.zero) {
        duration = controller.value.duration;
      }
      if (controller.value.aspectRatio != 0) {
        sourceAspect = controller.value.aspectRatio;
      }
      avEditorLog('load: exoplayer path=$probePath');

      if (!mounted) {
        await controller?.dispose();
        return;
      }

      final project = playable.duration == Duration.zero
          ? VideoProject(
              id: playable.id,
              sourcePath: sourcePath,
              duration: duration,
              trim: ClipTrim(start: Duration.zero, end: duration),
              // Keep any cuts already saved before duration was known.
              segments: List<ClipSegment>.from(playable.segments),
              mediaAssets: playable.mediaAssets
                  .map((a) => a.copyWith())
                  .toList(),
              overlays: playable.overlays,
              musicTracks: List<ProjectMusic>.from(playable.musicTracks),
              preset: playable.preset,
              canvas: playable.canvas,
              rotation: playable.rotation,
              name: playable.name,
              updatedAt: playable.updatedAt,
            )
          : playable;

      // Normalize a copy first — clearing in place then reading the same list
      // would wipe cuts (empty → single full-length segment).
      final normalized = normalizeSegments(
        List<ClipSegment>.from(project.segments),
        mediaAssets: project.mediaAssets,
        sourceDuration: duration,
      );
      project.segments
        ..clear()
        ..addAll(
          normalized.isEmpty || totalKeptDuration(normalized) <= Duration.zero
              ? (duration > Duration.zero
                    ? segmentsFromTrim(start: Duration.zero, end: duration)
                    : const <ClipSegment>[])
              : normalized,
        );
      _syncPackedDuration(project);

      _slotMain = controller;
      _slotsSwapped = false;
      _ffmpegPlayback = false;
      _sourceAspect = sourceAspect;
      _project = project;
      await _attachTimelineCompositor();
      if (!mounted || !_ownsEngine) {
        await controller?.dispose();
        return;
      }

      // Wait for timeline frames before revealing — no opening spinner page.
      await _loadFilmstrip(project);
      if (!mounted || !_ownsEngine) {
        await controller?.dispose();
        return;
      }

      setState(() {
        _ready = true;
        _errorMessage = null;
        _convertProgress = null;
        // Clear until decode finishes — photo-only projects must not keep a
        // stale audio band from a previous video project.
        _hasSourceAudio = false;
        _sourceAudioWaveforms.clear();
        _sourceAudioDurations.clear();
      });
      widget.onReady?.call();
      unawaited(_maybeStartOnboarding());
      unawaited(_loadMusicWaveforms(project));
      unawaited(_loadSourceAudioWaveforms(project));

      if (stored.duration == Duration.zero) {
        _scheduleSave();
      }
    } catch (e, st) {
      avEditorLog('editor load failed: $e');
      debugPrint('$st');
      if (!mounted) return;
      setState(() {
        _ready = true;
        _errorMessage = e.toString();
      });
      widget.onReady?.call();
    }
  }

  Future<VideoPlayerController?> _openPlayableController(String path) async {
    final file = File(path);
    final exists = await file.exists();
    final length = exists ? await file.length() : 0;
    avEditorLog('video open attempt path=$path exists=$exists bytes=$length');
    if (!exists || length <= 0) {
      avEditorLog('video open failed: missing or empty file');
      return null;
    }

    // One retry covers slow Photos/iCloud exports that finish writing just
    // after the first initialize attempt.
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      final controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
        if (controller.value.hasError) {
          throw StateError(
            controller.value.errorDescription ?? 'video open failed',
          );
        }
        if (controller.value.duration <= Duration.zero) {
          throw StateError('video open failed: zero duration');
        }
        return controller;
      } catch (error, stack) {
        lastError = error;
        avEditorLog('video open failed attempt=${attempt + 1}: $error\n$stack');
        await controller.dispose();
      }
    }
    avEditorLog('video open failed permanently: $lastError');
    return null;
  }

  Future<void> _loadFilmstrip(VideoProject project) async {
    late final List<TimelineFilmstripFrame> frames;
    try {
      frames = await _thumbnailService.loadProjectFilmstrip(project);
    } catch (error, stack) {
      avEditorLog('filmstrip failed: $error\n$stack');
      return;
    }
    if (!mounted) {
      for (final frame in frames) {
        frame.image.dispose();
      }
      return;
    }
    // Swap first, then dispose — painting a disposed ui.Image blanks tiles.
    final previous = _filmstripFrames;
    setState(() => _filmstripFrames = frames);
    for (final frame in previous) {
      frame.image.dispose();
    }
    avEditorLog('filmstrip loaded frames=${frames.length}');
  }

  Future<void> _addTimelineMedia() async {
    final project = _project;
    if (project == null || _appendingMedia || _exporting) return;

    List<String> paths;
    Duration? imageHoldDuration;
    try {
      if (PlatformHelper.supportsGallery) {
        final batch = await _import.pickFromGallery(context);
        paths = batch.paths;
        imageHoldDuration = batch.imageHoldDuration;
      } else if (PlatformHelper.supportsFilePicker) {
        paths = await _import.pickFromFiles();
      } else {
        return;
      }
    } catch (e, st) {
      if (!mounted) return;
      final detail = e.toString();
      final message = detail.contains('empty_video')
          ? context.l10n.videoPickEmpty
          : context.l10n.videoPickError(detail);
      showLoggedSnackBar(context, message, error: e, stackTrace: st);
      return;
    }
    if (!mounted || paths.isEmpty) return;

    final joinAt = exportTimelineDuration(project.segments);
    final priorAssetIds = project.mediaAssets.map((a) => a.id).toSet();
    final rollback = _snapshot();
    _history.record(rollback);
    setState(() {
      _appendingMedia = true;
      _convertProgress = null;
    });

    try {
      final updated = await _projectStorage.appendImports(
        project,
        paths,
        imageHoldDuration: imageHoldDuration,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _convertProgress = p.clamp(0.0, 1.0));
        },
      );
      if (!mounted) return;
      _project = updated;
      _selectedSegmentId = updated.segments.isEmpty
          ? null
          : updated.segments.last.id;
      _selectedOverlayId = null;
      _selectedMusicId = null;
      _selectedTransitionAfterIndex = null;
      _syncPackedDuration(updated);
      setState(() {
        _appendingMedia = false;
        _convertProgress = null;
      });
      await _attachTimelineCompositor(resume: false, seekTo: joinAt);
      if (!mounted) return;
      await _syncSourceAspectFromProject(updated);
      if (!mounted) return;
      unawaited(_loadFilmstrip(updated));
      unawaited(_loadSourceAudioWaveforms(updated));
      _scheduleSave();
      AnalyticsService.instance.log('timeline_media_appended');
    } catch (e, st) {
      if (!mounted) return;
      rollback.applyTo(project);
      project.mediaAssets.removeWhere((a) => !priorAssetIds.contains(a.id));
      _syncPackedDuration(project);
      _selectedSegmentId = rollback.selectedSegmentId;
      _selectedOverlayId = rollback.selectedOverlayId;
      _selectedMusicId = rollback.selectedMusicId;
      setState(() {
        _appendingMedia = false;
        _convertProgress = null;
      });
      final detail = e.toString();
      final message = detail.contains('empty_video')
          ? context.l10n.videoPickEmpty
          : context.l10n.videoPickError(detail);
      showLoggedSnackBar(context, message, error: e, stackTrace: st);
    }
  }

  void _syncPackedDuration(VideoProject project) {
    final packed = exportTimelineDuration(project.segments);
    if (packed != project.duration) {
      // Includes Duration.zero after deleting the last clip.
      project.duration = packed;
    }
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
      // Panel owns the compositor while open — save must not preroll/seek.
      if (_transitionPreviewArmed || _transitionStudioCutIndex != null) {
        return;
      }
      // Mid trim/hold drag: packed rebuild is coalesced via
      // [_schedulePackedEdgeRebuild]; a save attach would race a stale pack.
      if (_edgeFramePreviewActive) {
        return;
      }
      // Never rebuild/preroll while the user is watching — that paused playback
      // at whatever frame they had reached (often a cut).
      if (NativeVideoEngine.instance.isPlaying) {
        return;
      }
      // A pending layout rebuild already targets the right seek.
      if (_segmentLayoutRebuildDebounce?.isActive ?? false) {
        return;
      }
      unawaited(_attachTimelineCompositor());
    });
  }

  void _scheduleSegmentLayoutRebuild({Duration? seekTo}) {
    if (_transitionPreviewArmed || _transitionStudioCutIndex != null) {
      return;
    }
    _segmentLayoutRebuildDebounce?.cancel();
    _segmentLayoutRebuildDebounce = Timer(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      final land = seekTo ?? _scrubPlayhead ?? _playhead;
      unawaited(_attachTimelineCompositor(resume: false, seekTo: land));
    });
  }

  /// Rebuild the packed compositor from the live dragged segments and seek to
  /// the edge. Coalesces so only the newest drag state is shown — queued
  /// intermediate prepares were flashing pre-drag ↔ mid-drag packs.
  void _schedulePackedEdgeRebuild(Duration seekTo) {
    if (_transitionPreviewArmed || _transitionStudioCutIndex != null) {
      return;
    }
    _pendingPackedEdgeSeek = seekTo;
    _segmentLayoutRebuildDebounce?.cancel();
    _segmentLayoutRebuildDebounce = Timer(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      unawaited(_drainPackedEdgeRebuild());
    });
  }

  Future<void> _drainPackedEdgeRebuild() async {
    if (_packedEdgeRebuildInFlight) return;
    _packedEdgeRebuildInFlight = true;
    try {
      while (mounted && _pendingPackedEdgeSeek != null) {
        final land = _pendingPackedEdgeSeek!;
        _pendingPackedEdgeSeek = null;
        await _attachTimelineCompositor(resume: false, seekTo: land);
      }
    } finally {
      _packedEdgeRebuildInFlight = false;
      if (mounted && _pendingPackedEdgeSeek != null) {
        unawaited(_drainPackedEdgeRebuild());
      }
    }
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
    } catch (error) {
      rollback.applyTo(project);
      rethrow;
    }
  }

  void _ensureHealthySegments(VideoProject project) {
    // Empty picture track is valid (user deleted every clip).
    if (project.segments.isEmpty) {
      if (project.duration != Duration.zero) {
        project.duration = Duration.zero;
      }
      return;
    }
    if (project.duration <= Duration.zero) return;

    var fixed = normalizeSegments(
      project.segments,
      mediaAssets: project.mediaAssets,
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
      if (a[i].start != b[i].start ||
          a[i].end != b[i].end ||
          a[i].mediaId != b[i].mediaId) {
        return false;
      }
    }
    return true;
  }

  Duration _sequenceTimeForSplit(
    List<ClipSegment> segments,
    Duration rawPlayhead,
  ) {
    final kept = totalKeptDuration(segments);
    if (kept <= Duration.zero) return Duration.zero;

    var sequenceTime = _usesPackedPlayhead
        ? rawPlayhead
        : timelinePlayheadFromSource(segments, rawPlayhead);
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
    final packedClock = project.mediaAssets.isNotEmpty;

    try {
      late final List<ClipSegment> newSegments;
      late final Duration splitPoint;
      if (packedClock) {
        if (segmentIndexAtSequenceTime(working, sequenceTime) < 0) {
          throw StateError('split_out_of_range');
        }
        newSegments = splitSegmentsAtSequenceTime(working, sequenceTime);
        splitPoint = exportTimeToSourceTime(newSegments, sequenceTime);
      } else {
        final playhead = splitSourceFromSequence(working, sequenceTime);
        if (!isInKeptRegion(working, playhead)) {
          throw StateError('split_out_of_range');
        }
        splitPoint = resolveSplitPoint(working, playhead);
        if (isAlreadySplitAt(working, splitPoint)) {
          OverlayEventLog.log('split', 'already_split', {
            'sequenceTime': sequenceTime,
            'splitPoint': splitPoint,
          });
          return;
        }
        newSegments = splitSegmentsAt(working, splitPoint);
      }

      OverlayEventLog.log('split', 'attempt', {
        'rawPlayhead': rawPlayhead,
        'sequenceTime': sequenceTime,
        'splitPoint': splitPoint,
        'segmentCount': working.length,
        'segmentDurations': working
            .map((segment) => segment.duration.inMilliseconds)
            .join(','),
      });

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
        _syncPackedDuration(p);
        _selectedSegmentId = (rightPiece ?? newSegments.last).id;
        _selectedOverlayId = null;
        _selectedMusicId = null;
      });
      OverlayEventLog.log('split', 'success', {
        'sequenceTime': sequenceTime,
        'newSegmentCount': project.segments.length,
      });
      unawaited(_requestSplitTransitionTip());
    } on StateError catch (e, st) {
      OverlayEventLog.log('split', 'failed', {
        'code': e.message,
        'rawPlayhead': rawPlayhead,
        'sequenceTime': sequenceTime,
        'segmentDurations': project.segments
            .map((segment) => segment.duration.inMilliseconds)
            .join(','),
      });
      _showSnack(_splitErrorMessage(e.message), error: e, stackTrace: st);
    }
  }

  void _deleteSelectedSegment() {
    final project = _project;
    final segmentId = _selectedSegmentId;
    if (project == null || segmentId == null || _exporting) return;

    final updated = deleteSegment(project.segments, segmentId);
    _mutate((p) {
      p.segments
        ..clear()
        ..addAll(updated);
      _syncPackedDuration(p);
      _selectedSegmentId = null;
      _selectedTransitionAfterIndex = null;
    });
    final land = updated.isEmpty
        ? Duration.zero
        : clampDuration(_playhead, Duration.zero, project.duration);
    unawaited(() async {
      await _attachTimelineCompositor(resume: false, seekTo: land);
      if (!mounted) return;
      await _syncSourceAspectFromProject(project);
    }());
    if (updated.isEmpty) {
      unawaited(_loadFilmstrip(project));
      unawaited(_loadSourceAudioWaveforms(project));
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

  void _showSnack(String message, {Object? error, StackTrace? stackTrace}) {
    if (!mounted) return;
    showLoggedSnackBar(context, message, error: error, stackTrace: stackTrace);
  }

  String _timelineSig = '';
  StreamSubscription<Duration>? _timelinePositionSub;
  Future<void>? _timelineAttachTask;

  void _applyNativePreviewAspect() {
    final engine = NativeVideoEngine.instance;
    if (engine.previewWidth <= 0 || engine.previewHeight <= 0) return;
    final next = engine.previewWidth / engine.previewHeight;
    if ((next - _sourceAspect).abs() < 0.0001) return;
    _sourceAspect = next;
    if (mounted) setState(() {});
  }

  /// Refresh Original-canvas aspect from the first timeline video (or native
  /// preview size after prepare). Orphaned mediaAssets must not win.
  Future<void> _syncSourceAspectFromProject(VideoProject project) async {
    if (!mounted) return;
    if (NativeVideoEngine.instance.isTimelineActive) {
      _applyNativePreviewAspect();
      if (_sourceAspect > 0) return;
    }
    if (project.segments.isEmpty) return;
    try {
      final size = await _probe.readFrameSize(project.primaryVideoPath);
      if (!mounted || size.width <= 0 || size.height <= 0) return;
      final next = size.width / size.height;
      if ((next - _sourceAspect).abs() < 0.0001) return;
      setState(() => _sourceAspect = next);
    } catch (e) {
      debugPrint('[editor] source aspect sync failed: $e');
    }
  }

  Future<void> _attachTimelineCompositor({
    bool resume = true,
    Duration? seekTo,
  }) {
    final pending = _timelineAttachTask;
    Future<void> runBody() =>
        _attachTimelineCompositorBody(resume: resume, seekTo: seekTo);
    final run = pending == null ? runBody() : pending.then((_) => runBody());
    _timelineAttachTask = run.whenComplete(() {
      if (identical(_timelineAttachTask, run)) _timelineAttachTask = null;
    });
    return _timelineAttachTask!;
  }

  Future<void> _attachTimelineCompositorBody({
    required bool resume,
    Duration? seekTo,
  }) async {
    final project = _project;
    if (project == null ||
        !mounted ||
        !_ownsEngine ||
        !NativeVideoEngine.instance.isPlatformSupported) {
      return;
    }
    // Panel selection uses a short transition session — do not replace it.
    if (_spatialPreviewActive) return;
    // Background refresh (save debounce) must not pause mid-transition.
    if (_transitionPreviewArmed && seekTo == null) return;
    // Include sequence length so music/text tails past picture rebuild the
    // native black pad (segment signature alone stays the same).
    final sig =
        '${timelineCompositionSignature(project.segments)}|${_sequenceDuration.inMilliseconds}';
    if (project.segments.isEmpty) {
      if (sig == _timelineSig && !NativeVideoEngine.instance.isTimelineActive) {
        return;
      }
      _timelineSig = sig;
      await _timelinePositionSub?.cancel();
      _timelinePositionSub = null;
      await NativeVideoEngine.instance.dispose();
      try {
        await _controller?.pause();
        await _controller?.setVolume(0);
        await _auxController?.pause();
        await _auxController?.setVolume(0);
      } catch (_) {}
      if (mounted) setState(() {});
      return;
    }
    final desired =
        seekTo ??
        _pendingTimelineSeek ??
        _scrubPlayhead ??
        _nativePackedToSource(NativeVideoEngine.instance.position);
    final wasPlaying = resume && NativeVideoEngine.instance.isPlaying;
    if (sig == _timelineSig && NativeVideoEngine.instance.isTimelineActive) {
      // Same composition — never preroll during playback. preroll() pauses the
      // native player and used to leave it paused (save debounce mid-play →
      // freeze at the cut / playhead).
      final explicitSeek = seekTo ?? _pendingTimelineSeek;
      if (explicitSeek != null) {
        await NativeVideoEngine.instance.preroll(
          _sourceToNativePacked(explicitSeek),
        );
        if (wasPlaying) await NativeVideoEngine.instance.play();
      } else if (!NativeVideoEngine.instance.isPlaying &&
          desired > Duration.zero) {
        // Save runs while paused. Seeking the frame already on screen clears
        // the texture and the preview flashes black.
        final packed = _sourceToNativePacked(desired);
        final delta = (NativeVideoEngine.instance.position - packed)
            .inMilliseconds
            .abs();
        if (delta > 40) {
          await NativeVideoEngine.instance.preroll(packed);
        }
      }
      return;
    }
    _timelineSig = sig;
    var pos = desired;
    // After a short panel preview the native clock is 0 — never rebuild there.
    if (pos <= Duration.zero) {
      final pinned =
          _pendingTimelineSeek ?? _scrubPlayhead ?? _panelPreviewSourcePos;
      if (pinned != null && pinned > Duration.zero) {
        pos = pinned;
      } else if (_transitionStudioCutIndex != null) {
        final i = _transitionStudioCutIndex!;
        if (i >= 0 && i < project.segments.length) {
          pos = project.segments[i].end;
        }
      }
    }
    final id = await NativeVideoEngine.instance.prepareTimeline(
      sourcePath: project.primaryVideoPath,
      segments: project.segments,
      project: project,
      ffmpegPlayer: _ffmpegPlayback,
    );
    if (!mounted) return;
    await _timelinePositionSub?.cancel();
    _timelinePositionSub = null;
    if (!mounted || !_ownsEngine) return;
    if (id == null) {
      debugPrint(
        'timeline compositor failed; preview stays on the hard-cut player',
      );
      if (mounted) setState(() {});
      return;
    }
    _applyNativePreviewAspect();
    try {
      await _controller?.pause();
      await _controller?.setVolume(0);
      await _auxController?.pause();
      await _auxController?.setVolume(0);
    } catch (_) {}
    _timelinePositionSub = NativeVideoEngine.instance.positionStream.listen((
      packed,
    ) {
      if (!mounted || !NativeVideoEngine.instance.isTimelineActive) return;
      final current = _project;
      if (current == null) return;
      // Native clock is packed export time; segment ops use source time.
      final position = _nativePackedToSource(packed);

      // Panel preview: drop stale samples from before the preview seek landed.
      // Logs showed nativePos still at ~4617 while we had just prerolled to
      // 3892 — that false >= until stop left the texture on the start frame.
      if (_transitionPreviewArmed &&
          _transitionPreviewUntil != null &&
          !_transitionPreviewSeekConfirmed) {
        final start = _transitionPreviewWindowStart;
        final until = _transitionPreviewUntil!;
        final inWindow =
            start != null &&
            position >= start - const Duration(milliseconds: 50) &&
            position < until;
        if (!inWindow) {
          return;
        }
        _transitionPreviewSeekConfirmed = true;
      }

      // A clock that leaps past the window is the previous playhead or the
      // next piece after the blend. Stopping on it cuts the effect off.
      if (_transitionPreviewArmed && _transitionPreviewSeekConfirmed) {
        final furthest = _panelPreviewFurthestPos;
        if (furthest != null &&
            position > furthest + const Duration(milliseconds: 1000)) {
          return;
        }
      }

      if (_transitionStudioCutIndex != null) {
        // Monotonic: a stale native sample after pause must not snap UI/frame
        // tracking back to the transition window start.
        if (_panelPreviewSourcePos == null ||
            position > _panelPreviewSourcePos!) {
          _panelPreviewSourcePos = position;
        }
        if (_panelPreviewFurthestPos == null ||
            position > _panelPreviewFurthestPos!) {
          _panelPreviewFurthestPos = position;
        }
      }
      final until = _transitionPreviewUntil;
      // Bounded preview stop is panel-only. After the dock closes, leftover
      // until/armed must never freeze normal timeline playback at a cut.
      if (_transitionStudioCutIndex != null &&
          _transitionPreviewArmed &&
          _transitionPreviewSeekConfirmed &&
          until != null &&
          position >= until) {
        debugPrint(
          '[TL] panel.stop reason=position>=until '
          'position=${position.inMilliseconds}ms '
          'until=${until.inMilliseconds}ms '
          'nativePos=${packed.inMilliseconds}ms '
          'playing=${NativeVideoEngine.instance.isPlaying}',
        );
        // #region agent log
        debugAgentLog(
          'editor_screen.dart:positionStream',
          'panel.stop',
          hypothesisId: 'D',
          data: {
            'positionMs': position.inMilliseconds,
            'untilMs': until.inMilliseconds,
            'packedMs': packed.inMilliseconds,
            'playing': NativeVideoEngine.instance.isPlaying,
            'windowStartMs': _transitionPreviewWindowStart?.inMilliseconds,
            'seekConfirmed': _transitionPreviewSeekConfirmed,
          },
        );
        // #endregion
        unawaited(_stopTransitionPreview(reason: 'position>=until'));
        return;
      }
      // Multi-source packed clock: segment start/end are per-asset locals, so
      // isInKeptRegion(packed) falsely looks like a "gap" and seeks to 0.
      if (!_usesPackedPlayhead &&
          _scrubPlayhead == null &&
          _pendingTimelineSeek == null &&
          !isInKeptRegion(current.segments, position)) {
        final next = nextSegmentStartAfter(current.segments, position);
        if (next != null) {
          debugPrint(
            '[TL] playback.seek reason=gap '
            'position=${position.inMilliseconds}ms '
            'next=${next.inMilliseconds}ms',
          );
          // Native seek() pauses — resume so a gap at a split does not freeze.
          unawaited(
            NativeVideoEngine.instance.seek(
              _sourceToNativePacked(next),
              resume: true,
            ),
          );
        }
      }
      // Keep source-audio volume/fade envelope in sync with the native clock
      // (Flutter VideoPlayer is muted while the timeline engine owns audio).
      _syncVideoAudioVolume();
      unawaited(_syncMusicOnTick());
      // Native often ends at picture EOF; hand off to wall-clock black tail.
      _maybeContinuePastPicture(position: position);
      setState(() {});
    });
    await _timelinePlayingSub?.cancel();
    _timelinePlayingSub = NativeVideoEngine.instance.playingStream.listen((
      playing,
    ) {
      if (!mounted) return;
      if (!playing) {
        final land =
            _scrubPlayhead ??
            _nativePackedToSource(NativeVideoEngine.instance.position);
        _maybeContinuePastPicture(position: land);
      }
      setState(() {});
    });
    if (!mounted || !_ownsEngine) return;
    await NativeVideoEngine.instance.preroll(_sourceToNativePacked(pos));
    if (!mounted || !_ownsEngine) return;
    _logTimeline('attach.preroll', land: pos);
    if (wasPlaying) {
      _wantPlayback = true;
      await NativeVideoEngine.instance.play();
    }
    if (mounted) setState(() {});
  }

  void _advancePlaybackPastGaps() {
    if (NativeVideoEngine.instance.isTimelineActive) return;
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null || !controller.value.isPlaying) {
      return;
    }
    if (_fadeHandoffInFlight) return;
    // Multi-source: the Flutter VideoPlayer only has one file. Seeking to the
    // next clip's local start (often 0) looks like a jump back to the beginning.
    if (project.mediaAssets.isNotEmpty) return;

    final pos = controller.value.position;

    final fade = previewFadeAt(project.segments, pos);
    if (fade != null) {
      final entering = _fadeAnchoredAfterIndex != fade.afterIndex;
      _activeFade = fade;
      if (NativeVideoEngine.supports(fade.outgoing.transition)) {
        if (entering) {
          _fadeProgressPeak = fade.t;
          if (controller.value.isPlaying) {
            _beginFadeWallClock(fade.t);
          } else {
            _fadeWallClockStart = null;
          }
        }
        if (entering || !_spatialPreviewActive) {
          unawaited(
            _showSpatialPreviewAt(fade, playing: controller.value.isPlaying),
          );
        } else {
          if (controller.value.isPlaying && _fadeWallClockStart == null) {
            _beginFadeWallClock(_fadeProgress ?? fade.t);
          }
          _setFadeProgress(fade.t, playing: controller.value.isPlaying);
        }
        return;
      }
      if (entering) {
        unawaited(_tearDownSpatialPreview());
        _fadeProgressPeak = fade.t;
        if (controller.value.isPlaying) {
          _beginFadeWallClock(fade.t);
        } else {
          _fadeWallClockStart = null;
        }
      }
      if (entering || _auxController == null) {
        // Only the first entry into a cut does async seek/play setup.
        unawaited(_driveFadePreview(fade));
      } else {
        // Already anchored — update blend progress without reseeking.
        if (controller.value.isPlaying && _fadeWallClockStart == null) {
          _beginFadeWallClock(_fadeProgress ?? fade.t);
        }
        _setFadeProgress(fade.t, playing: controller.value.isPlaying);
        final aux = _auxController;
        if (controller.value.isPlaying) {
          unawaited(
            _safeVideo(aux, (player) async {
              if (!player.value.isPlaying) await player.play();
            }),
          );
        }
      }
      // The source file keeps playing past the cut, so the outgoing slot would
      // show the incoming clip. Hold A's last frame and finish the blend on
      // the wall clock.
      if (controller.value.isPlaying && pos >= fade.outgoing.end) {
        _holdOutgoingAtCut(fade);
      }
      return;
    }

    if (_activeFade != null) {
      final active = _activeFade!;
      // Past window end → hand off (aux is already at B[start+⌈td/2⌉]).
      if (pos >= active.windowEnd) {
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
      final windowStart = active.windowStart;
      if (pos >= windowStart && pos < active.windowEnd) {
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
          controller.seekTo(next);
          unawaited(_syncMusicPlayback());
        } else {
          controller.pause();
          controller.seekTo(segment.end);
          if (!_tryStartSequenceTail(from: segment.end)) {
            unawaited(_syncMusicPlayback());
          }
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
      if (!_tryStartSequenceTail(from: last.end)) {
        unawaited(_syncMusicPlayback());
      }
    }
  }

  /// Continue playhead + music after picture EOF (black canvas).
  /// Works with native timeline too — native clock often stops at video end.
  bool _tryStartSequenceTail({required Duration from}) {
    final end = _sequenceDuration;
    if (end <= from) return false;
    if (_sequenceTailPlaying) return true;
    // Mark first so a pause→playing=false event cannot start a second tail.
    _wantPlayback = true;
    _sequenceTailPlaying = true;
    if (NativeVideoEngine.instance.isTimelineActive &&
        NativeVideoEngine.instance.isPlaying) {
      unawaited(NativeVideoEngine.instance.pause());
    }
    _sequenceTailTimer?.cancel();
    _sequenceTailAnchorAt = DateTime.now();
    _sequenceTailAnchorPlayhead = from;
    _scrubPlayhead = from;
    _sequenceTailTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || !_sequenceTailPlaying) {
        _stopSequenceTail();
        return;
      }
      final now = _playhead;
      if (now >= _sequenceDuration) {
        _stopSequenceTail(land: _sequenceDuration, endPlayback: true);
        return;
      }
      _scrubPlayhead = now;
      unawaited(_syncMusicOnTick());
      setState(() {});
    });
    unawaited(_syncMusicPlayback());
    setState(() {});
    return true;
  }

  void _stopSequenceTail({Duration? land, bool endPlayback = false}) {
    _sequenceTailTimer?.cancel();
    _sequenceTailTimer = null;
    _sequenceTailPlaying = false;
    _sequenceTailAnchorAt = null;
    _sequenceTailAnchorPlayhead = null;
    if (endPlayback) _wantPlayback = false;
    if (land != null) _scrubPlayhead = land;
    unawaited(_syncMusicPlayback());
    if (mounted) setState(() {});
  }

  /// When native stops at picture EOF but music/text continue past it.
  void _maybeContinuePastPicture({required Duration position}) {
    if (_sequenceTailPlaying || !_wantPlayback) return;
    final project = _project;
    if (project == null || project.segments.isEmpty) return;
    final videoEnd = exportTimelineDuration(project.segments);
    final seqEnd = _sequenceDuration;
    if (seqEnd <= videoEnd) return;
    if (position < videoEnd - const Duration(milliseconds: 80)) return;
    final from = position < videoEnd ? videoEnd : position;
    if (from >= seqEnd) return;
    _tryStartSequenceTail(from: from);
  }

  /// Commit dual-layer blend progress. Flutter dual-player uses wall clock;
  /// spatial panel preview is driven only by native position — never seek.
  void _setFadeProgress(double t, {required bool playing}) {
    var clamped = t.clamp(0.0, 1.0);
    // Short prepareTransition session: AVPlayer owns time. Wall-clock seeks
    // reset nativePos→0 and pin the playhead at the transition start.
    if (_spatialPreviewActive) {
      if (playing) {
        final next = clamped < _fadeProgressPeak ? _fadeProgressPeak : clamped;
        _fadeProgressPeak = next;
        if (_fadeProgress == next) return;
        setState(() => _fadeProgress = next);
        return;
      }
      _fadeWallClockStart = null;
      _fadeProgressPeak = clamped;
      if (_fadeProgress == clamped) return;
      setState(() => _fadeProgress = clamped);
      return;
    }
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
      if (_fadeProgress == next) return;
      setState(() => _fadeProgress = next);
      return;
    }
    _fadeWallClockStart = null;
    _fadeProgressPeak = clamped;
    if (_fadeProgress == clamped) return;
    setState(() => _fadeProgress = clamped);
  }

  Future<void> _showSpatialPreviewAt(
    PreviewFadeWindow fade, {
    required bool playing,
  }) async {
    final project = _project;
    final main = _controller;
    final transition = fade.outgoing.transition;
    if (project == null || main == null || transition == null) return;
    // One playback path on every platform that has the native engine:
    // the same composition plan timeline preview and export already share.
    if (NativeVideoEngine.instance.isPlatformSupported &&
        NativeVideoEngine.supports(transition)) {
      final at =
          fade.windowStart +
          Duration(milliseconds: (fade.t * fade.td.inMilliseconds).round());
      await _tearDownSpatialPreview();
      await _attachTimelineCompositor(resume: playing, seekTo: at);
      return;
    }
    unawaited(_driveFadePreview(fade));
    _setFadeProgress(fade.t, playing: playing);
  }

  void _onNativeSpatialPosition(Duration position) {
    final active = _activeFade;
    if (!_spatialPreviewActive || active == null || !mounted) return;
    final td = active.td;
    if (td <= Duration.zero) return;

    final start = active.windowStart;
    final mapped = start + position;
    final endSource = active.windowEnd;
    // Always track the furthest source time reached so close lands past the cut.
    final clampedMapped = mapped < start
        ? start
        : (mapped > endSource ? endSource : mapped);
    if (_panelPreviewSourcePos == null ||
        clampedMapped > _panelPreviewSourcePos!) {
      _panelPreviewSourcePos = clampedMapped;
    }
    if (_panelPreviewFurthestPos == null ||
        clampedMapped > _panelPreviewFurthestPos!) {
      _panelPreviewFurthestPos = clampedMapped;
    }

    final t = (position.inMilliseconds / td.inMilliseconds).clamp(0.0, 1.0);
    _activeFade = PreviewFadeWindow(
      afterIndex: active.afterIndex,
      t: t,
      outgoing: active.outgoing,
      incoming: active.incoming,
      td: active.td,
    );
    _setFadeProgress(t, playing: NativeVideoEngine.instance.isPlaying);

    if (position >= td - const Duration(milliseconds: 50)) {
      if (!_fadeHandoffInFlight) {
        unawaited(_finishSpatialTransitionPreview(active));
      }
    }
    setState(() {});
  }

  /// Panel item preview finished — freeze on the last frame at source end (e.g. 5).
  /// Do not seek back to the transition start (1).
  Future<void> _finishSpatialTransitionPreview(PreviewFadeWindow done) async {
    if (_fadeHandoffInFlight) return;
    _fadeHandoffInFlight = true;
    try {
      await NativeVideoEngine.instance.pause();
      final end = done.td;
      if (end > Duration.zero) {
        await NativeVideoEngine.instance.seek(end);
        await NativeVideoEngine.instance.preroll(end);
      }
      // Source time at preview end = cut + ⌈td/2⌉ (solo B start). Never window start.
      final endSource = done.windowEnd;
      _panelPreviewSourcePos = endSource;
      _panelPreviewFurthestPos = endSource;
      _scrubPlayhead = endSource;
      _pendingTimelineSeek = endSource;
      _activeFade = null;
      _clearFadeProgress();
      _fadeAnchoredAfterIndex = null;
      _logTimeline('panel.finish', land: endSource);
      if (mounted) setState(() {});
      unawaited(_syncMusicPlayback());
    } finally {
      _fadeHandoffInFlight = false;
    }
  }

  Future<void> _completeSpatialHandoff(PreviewFadeWindow done) async {
    if (_fadeHandoffInFlight) return;
    _fadeHandoffInFlight = true;
    try {
      final main = _controller;
      final project = _project;
      if (main == null || project == null) return;

      await NativeVideoEngine.instance.pause();
      await _tearDownSpatialPreview();

      _activeFade = null;
      _clearFadeProgress();
      _fadeAnchoredAfterIndex = null;

      final target = clampDuration(
        done.windowEnd,
        Duration.zero,
        project.duration,
      );

      await _restoreTimelineAt(target);
      if (mounted) setState(() {});
      unawaited(_syncMusicPlayback());
      _syncVideoAudioVolume();
    } finally {
      _fadeHandoffInFlight = false;
    }
  }

  Future<void> _restoreTimelineAt(Duration target) async {
    final project = _project;
    if (project == null) return;
    final clamped = clampDuration(target, Duration.zero, project.duration);
    _logTimeline('restore.before', land: clamped);
    _pendingTimelineSeek = clamped;
    _scrubPlayhead = clamped;
    // Force rebuild even if sig matches — session may have been a short preview.
    _timelineSig = '';
    await _attachTimelineCompositor(resume: false, seekTo: clamped);
    if (NativeVideoEngine.instance.isTimelineActive) {
      await NativeVideoEngine.instance.preroll(_sourceToNativePacked(clamped));
    }
    // Keep Flutter fallback decoder on the same frame.
    try {
      await _controller?.seekTo(clamped);
      await _controller?.pause();
    } catch (_) {}
    _pendingTimelineSeek = null;
    // Keep scrub pinned so a 0 native clock cannot move the playhead to start.
    _scrubPlayhead = clamped;
    _logTimeline('restore.after', land: clamped);
    if (mounted) setState(() {});
  }

  Future<void> _tearDownSpatialPreview({bool keepGen = false}) async {
    if (!keepGen) {
      _spatialPreviewGen++;
    }
    _spatialPreviewActive = false;
    _spatialTextureId = null;
    await _spatialPositionSub?.cancel();
    await _spatialPlayingSub?.cancel();
    _spatialPositionSub = null;
    _spatialPlayingSub = null;
    // Timeline mode shares this engine — do not dispose it for dual-layer cleanup.
    if (NativeVideoEngine.instance.isTimelineActive) return;
    if (!_ownsEngine) return;
    await NativeVideoEngine.instance.dispose();
  }

  void _clearFadeProgress() {
    _stopFadeHold();
    _fadeHoldShouldResume = false;
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

  void _holdOutgoingAtCut(PreviewFadeWindow fade) {
    if (_outgoingHeld || _fadeHandoffInFlight) return;
    _outgoingHeld = true;
    _fadeHoldShouldResume = true;
    if (_fadeWallClockStart == null) {
      _beginFadeWallClock(fade.t);
    }
    final main = _controller;
    if (main != null) {
      unawaited(main.pause());
      unawaited(main.seekTo(fade.outgoing.end));
    }
    unawaited(_auxController?.pause() ?? Future<void>.value());
    _fadeHoldTimer?.cancel();
    _fadeHoldTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _tickFadeHold();
    });
  }

  void _tickFadeHold() {
    if (!mounted || _fadeHandoffInFlight) {
      _stopFadeHold();
      return;
    }
    final active = _activeFade;
    if (active == null) {
      _stopFadeHold();
      return;
    }
    _setFadeProgress(active.t, playing: true);
    final t = _fadeProgress ?? active.t;
    if (t >= 0.999) {
      _stopFadeHold();
      unawaited(_completeFadeHandoff(active));
      return;
    }
    final updated = PreviewFadeWindow(
      afterIndex: active.afterIndex,
      t: t,
      outgoing: active.outgoing,
      incoming: active.incoming,
      td: active.td,
    );
    _activeFade = updated;
    final aux = _auxController;
    if (!_isLiveVideo(aux)) return;
    final target = updated.auxSourceTime;
    final drift = (aux!.value.position - target).inMilliseconds.abs();
    if (drift > 40) {
      unawaited(_safeVideo(aux, (player) => player.seekTo(target)));
    }
  }

  void _stopFadeHold() {
    _fadeHoldTimer?.cancel();
    _fadeHoldTimer = null;
    _outgoingHeld = false;
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
    if (previous != null) {
      _fadeSyncGen++;
    }
    _slotAux = aux;
    await previous?.dispose();
    if (mounted) setState(() {});
  }

  /// True when [controller] is still the live slot and has not been disposed.
  bool _isLiveVideo(VideoPlayerController? controller) {
    if (controller == null) return false;
    if (!identical(controller, _controller) &&
        !identical(controller, _auxController) &&
        !identical(controller, _slotMain) &&
        !identical(controller, _slotAux)) {
      return false;
    }
    try {
      return controller.value.isInitialized;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _safeVideo(
    VideoPlayerController? controller,
    Future<void> Function(VideoPlayerController player) action,
  ) async {
    if (!_isLiveVideo(controller)) return false;
    try {
      await action(controller!);
      return true;
    } catch (error) {
      debugPrint('video controller call skipped: $error');
      return false;
    }
  }

  Future<void> _driveFadePreview(PreviewFadeWindow fade) async {
    // Do NOT bump _fadeSyncGen here — every tick used to cancel in-flight
    // seeks and made the incoming layer hitch / jump backward.
    final gen = _fadeSyncGen;
    if (_controller == null || _fadeHandoffInFlight) return;

    await _ensureAuxController();
    if (!mounted || gen != _fadeSyncGen) return;
    final aux = _auxController;
    final main = _controller;
    if (!_isLiveVideo(aux) || !_isLiveVideo(main)) return;

    final target = fade.auxSourceTime;
    if (_fadeAnchoredAfterIndex != fade.afterIndex) {
      _fadeAnchoredAfterIndex = fade.afterIndex;
      await _safeVideo(aux, (player) => player.pause());
      if (!mounted || gen != _fadeSyncGen || !_isLiveVideo(aux)) return;
      await _safeVideo(aux, (player) => player.seekTo(target));
      if (!mounted || gen != _fadeSyncGen || !_isLiveVideo(aux)) return;
      // Wait briefly so the first incoming frame is decoded before blending.
      final deadline = DateTime.now().add(const Duration(milliseconds: 200));
      while (DateTime.now().isBefore(deadline)) {
        if (!mounted || gen != _fadeSyncGen || !_isLiveVideo(aux)) return;
        final int drift;
        final bool buffering;
        try {
          drift = (aux!.value.position - target).inMilliseconds.abs();
          buffering = aux.value.isBuffering;
        } catch (_) {
          return;
        }
        if (drift <= 50 && !buffering) break;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!mounted || gen != _fadeSyncGen || !_isLiveVideo(aux)) return;
      if (_isLiveVideo(main) && main!.value.isPlaying) {
        await _safeVideo(aux, (player) => player.play());
      }
    } else {
      // Keep aux on B[start, start+⌈td/2⌉) — seek when drift exceeds a frame
      // so we don't play into identical post-cut frames (invisible dissolve).
      try {
        final drift = (aux!.value.position - target).inMilliseconds.abs();
        if (drift > 80) {
          await _safeVideo(aux, (player) => player.seekTo(target));
        }
      } catch (_) {}
      if (_isLiveVideo(main) && main!.value.isPlaying) {
        if (_isLiveVideo(aux) && !aux!.value.isPlaying) {
          await _safeVideo(aux, (player) => player.play());
        }
      } else if (_isLiveVideo(aux) && aux!.value.isPlaying) {
        await _safeVideo(aux, (player) => player.pause());
      }
    }
    if (!mounted || gen != _fadeSyncGen || !_isLiveVideo(main)) return;

    _setFadeProgress(fade.t, playing: main!.value.isPlaying);
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

      final resumePlayback = _fadeHoldShouldResume;
      _fadeHoldShouldResume = false;

      // Fallback: no aux → hard seek (should be rare).
      if (aux == null || !aux.value.isInitialized) {
        final half = transitionHalfMs(done.td);
        final handoff =
            done.incoming.start + Duration(milliseconds: half.after);
        final land = handoff > done.incoming.end ? done.incoming.end : handoff;
        await main.seekTo(land < done.windowEnd ? done.windowEnd : land);
        _activeFade = null;
        _clearFadeProgress();
        _fadeAnchoredAfterIndex = null;
        if (resumePlayback && mounted) {
          await main.play();
        }
        if (mounted) setState(() {});
        return;
      }

      final wasPlaying =
          resumePlayback ||
          main.value.isPlaying ||
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

      final pastCut = done.windowEnd;
      if (_controller!.value.position < pastCut) {
        await _controller!.seekTo(pastCut);
      }
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

  Widget _buildPreviewVideoChild(VideoPlayerController? _) {
    // All clips deleted — do not fall back to the orphaned hard-cut player.
    if (_project?.segments.isEmpty ?? false) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    if (NativeVideoEngine.instance.isTimelineActive) {
      return NativeVideoEngine.instance.buildPreview();
    }
    if (_spatialPreviewActive &&
        _spatialTextureId != null &&
        NativeVideoEngine.instance.hasFrame) {
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

  Future<void> _loadSourceAudioWaveforms(VideoProject project) async {
    final peaksByMedia = <String, List<double>>{};
    final durationByMedia = <String, Duration>{};
    var anyAudio = false;

    // Decode once per path, then attach peaks to every mediaId on that file.
    final peaksByPath = <String, AudioWaveformData>{};
    final assets = project.mediaAssets;

    Future<AudioWaveformData?> decodePath(String path) async {
      final cached = peaksByPath[path];
      if (cached != null) return cached;
      if (MediaConcatService.isImagePath(path)) return null;
      if (!await File(path).exists()) {
        avEditorLog('waveform missing file $path');
        return null;
      }
      final wave = await AudioWaveformService.instance.waveformForFile(path);
      if (!mounted ||
          wave == null ||
          wave.peaks.isEmpty ||
          !AudioWaveformService.looksLikeRealAudio(wave.peaks)) {
        avEditorLog('waveform decode empty path=$path');
        return null;
      }
      peaksByPath[path] = wave;
      return wave;
    }

    if (assets.isEmpty) {
      if (!MediaConcatService.isImagePath(project.sourcePath)) {
        final wave = await decodePath(project.sourcePath);
        if (wave != null) {
          anyAudio = true;
          final duration = wave.duration > Duration.zero
              ? wave.duration
              : project.duration;
          var keyed = false;
          for (final segment in project.segments) {
            final id = segment.mediaId;
            if (id == null) continue;
            peaksByMedia[id] = wave.peaks;
            durationByMedia[id] = duration;
            keyed = true;
          }
          if (!keyed) {
            peaksByMedia[''] = wave.peaks;
            durationByMedia[''] = duration;
          }
        }
      }
    } else {
      for (final asset in assets) {
        if (asset.isImage) continue;
        final path = project.absoluteMediaPath(asset);
        if (MediaConcatService.isImagePath(path)) continue;
        final wave = await decodePath(path);
        if (wave == null) continue;
        anyAudio = true;
        peaksByMedia[asset.id] = wave.peaks;
        durationByMedia[asset.id] = wave.duration > Duration.zero
            ? wave.duration
            : (asset.duration > Duration.zero ? asset.duration : wave.duration);
      }
    }

    if (!mounted) return;
    avEditorLog(
      'waveform loaded media=${peaksByMedia.length} anyAudio=$anyAudio',
    );
    setState(() {
      _hasSourceAudio = anyAudio;
      _sourceAudioWaveforms
        ..clear()
        ..addAll(peaksByMedia);
      _sourceAudioDurations
        ..clear()
        ..addAll(durationByMedia);
    });
  }

  void _syncVideoAudioVolume() {
    final controller = _controller;
    final project = _project;
    if (project == null) return;

    if (_spatialPreviewActive) {
      controller?.setVolume(0);
      _auxController?.setVolume(0);
      if (NativeVideoEngine.instance.isTimelineActive) {
        unawaited(NativeVideoEngine.instance.setVolume(0));
      }
      return;
    }

    final playhead = _playhead;
    final volume = sourceVolumeAtPlayhead(project.segments, playhead);

    // Native timeline owns audible source audio (Flutter players stay muted).
    if (NativeVideoEngine.instance.isTimelineActive) {
      controller?.setVolume(0);
      _auxController?.setVolume(0);
      unawaited(NativeVideoEngine.instance.setVolume(volume));
      return;
    }

    if (controller == null) return;

    final fade = previewFadeAt(project.segments, playhead);
    if (fade != null) {
      final outLocal = fade.outgoingSourceTime - fade.outgoing.start;
      final inLocal = fade.auxSourceTime - fade.incoming.start;
      final outVol = fade.outgoing.volumeAt(
        outLocal < Duration.zero ? Duration.zero : outLocal,
      );
      final inVol = fade.incoming.volumeAt(
        inLocal < Duration.zero ? Duration.zero : inLocal,
      );
      controller.setVolume(outVol * (1.0 - fade.t));
      _auxController?.setVolume(inVol * fade.t);
      return;
    }
    _auxController?.setVolume(0);
    controller.setVolume(volume);
  }

  void _onVideoTick() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null || !mounted) return;

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
    // Native timeline owns its clock — never disarm from the muted controller
    // (its stale position is often already past [until] and would stop at start).
    final previewUntil = _transitionPreviewUntil;
    if (previewUntil != null &&
        !NativeVideoEngine.instance.isTimelineActive &&
        pos >= previewUntil) {
      debugPrint(
        '[TL] panel.stop reason=controller>=until '
        'pos=${pos.inMilliseconds}ms '
        'until=${previewUntil.inMilliseconds}ms',
      );
      unawaited(_stopTransitionPreview(reason: 'controller>=until'));
      return;
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
    _segmentLayoutRebuildDebounce?.cancel();
    _transitionPreviewTimer?.cancel();
    _fadeHoldTimer?.cancel();
    _sequenceTailTimer?.cancel();
    _cancelVoiceTimers();
    unawaited(_voiceRecorder.dispose());
    unawaited(_timelinePositionSub?.cancel());
    unawaited(_timelinePlayingSub?.cancel());
    final project = _project;
    if (project != null) {
      unawaited(_projectStorage.save(project));
    }
    _fadeSyncGen++;
    _disposeFilmstrip();
    _slotMain?.removeListener(_onVideoTick);
    _slotAux?.removeListener(_onVideoTick);
    final main = _slotMain;
    final aux = _slotAux;
    _slotMain = null;
    _slotAux = null;
    unawaited(main?.dispose() ?? Future<void>.value());
    unawaited(aux?.dispose() ?? Future<void>.value());
    unawaited(NativeVideoEngine.instance.release(_engineClaim));
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
    required double canvasAspect,
    required TextOverlay overlay,
  }) {
    if (keyboard <= 0 || previewSlotH <= 0 || previewSlotW <= 0) return 0;

    const toolbarH = 52.0;
    const margin = 16.0;
    const previewPadTop = 4.0;

    final canvasW = previewSlotW;
    final canvasH = canvasW / canvasAspect;
    final scale = math.min(previewSlotW / canvasW, previewSlotH / canvasH);

    final box = overlayBoxForFrame(overlay, frameWidth: canvasW);
    final body = OverlayGeometry.bodyRect(
      previewW: canvasW,
      previewH: canvasH,
      box: box,
    );
    final canvasTop = (previewSlotH - canvasH * scale) / 2;
    final overlayBottomInBody = previewPadTop + canvasTop + body.bottom * scale;
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

  bool get _inStickerStudio => _stickerStudioOpen;

  void _seek(Duration position, {bool seekVideo = true}) {
    final controller = _controller;
    final project = _project;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    _wantPlayback = false;
    if (_sequenceTailPlaying) {
      _sequenceTailTimer?.cancel();
      _sequenceTailTimer = null;
      _sequenceTailPlaying = false;
      _sequenceTailAnchorAt = null;
      _sequenceTailAnchorPlayhead = null;
    }

    // Allow scrubbing through the full packed sequence (video ∪ music ∪ text).
    // Restricting to [project.duration] parked the centre playhead at EOF and
    // made longer audio tails unreachable even though the strip grew.
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
    if (NativeVideoEngine.instance.isTimelineActive) {
      if (NativeVideoEngine.instance.isPlaying) {
        unawaited(NativeVideoEngine.instance.pause());
      }
      final videoSeek = clampDuration(clamped, Duration.zero, project.duration);
      final packed = _sourceToNativePacked(videoSeek);
      unawaited(NativeVideoEngine.instance.seek(packed));
      unawaited(_syncMusicPlayback());
      setState(() {});
      return;
    }
    if (controller == null) return;
    // Scrubbing while playing used to fight the decoder every tick (clear scrub
    // → play continues → seek again) and the play/pause icon thrashed.
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
      unawaited(_auxController?.pause() ?? Future<void>.value());
    }
    final fade = previewFadeAt(project.segments, clamped);
    if (fade != null && NativeVideoEngine.supports(fade.outgoing.transition)) {
      _scrubPlayhead = clamped;
      unawaited(
        _showSpatialPreviewAt(fade, playing: false).then((_) {
          controller.seekTo(
            clampDuration(clamped, Duration.zero, project.duration),
          );
          unawaited(_syncMusicPlayback());
          _syncVideoAudioVolume();
        }),
      );
      setState(() {});
      return;
    }

    unawaited(_tearDownFadePreview());
    // Video decoder only has frames up to the source length — pin the last
    // frame while the UI playhead continues into a music/text-only tail.
    final videoSeek = clampDuration(clamped, Duration.zero, project.duration);
    controller.seekTo(videoSeek);
    unawaited(_syncMusicPlayback());
    _syncVideoAudioVolume();
    setState(() {});
  }

  /// While dragging a clip edge, keep the centre needle pinned.
  ///
  /// Multi-source: rebuild the pack from the dragged lengths and keep the
  /// preview on that centre — do not seek the handle/end (that is the
  /// post-release settle target). On pointer-up we land on the edge.
  void _onEdgeFramePreview(Duration? sourceTime) {
    final controller = _controller;
    final project = _project;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    if (sourceTime == null) {
      final land = _lastEdgePreviewSeek ?? _scrubPlayhead ?? _playhead;
      _edgeFramePreviewActive = false;
      _lastEdgePreviewSeek = null;
      _pendingPackedEdgeSeek = land;
      _scrubPlayhead = null;
      // Pointer-up: seek the edge so settle / header move matches the handle.
      unawaited(_drainPackedEdgeRebuild());
      return;
    }

    if (!_edgeFramePreviewActive) {
      _edgeFramePreviewActive = true;
      // Pin the timeline needle at the current centre for the whole drag.
      _scrubPlayhead = _playhead;
      if (_transportPlaying) {
        if (NativeVideoEngine.instance.isTimelineActive) {
          unawaited(NativeVideoEngine.instance.pause());
        } else {
          unawaited(controller?.pause());
        }
        unawaited(_syncMusicPlayback());
      }
      unawaited(_tearDownFadePreview());
    }

    final videoSeek = clampDuration(
      sourceTime,
      Duration.zero,
      project.duration,
    );

    // Multi-source: remember the handle for release, but preview the pinned
    // centre with the already-dragged pack (not the release/end frame).
    if (project.mediaAssets.isNotEmpty) {
      _lastEdgePreviewSeek = videoSeek;
      final centre = _scrubPlayhead ?? _playhead;
      _schedulePackedEdgeRebuild(centre);
      return;
    }

    if (_lastEdgePreviewSeek != null &&
        (videoSeek - _lastEdgePreviewSeek!).inMilliseconds.abs() < 16) {
      return;
    }
    _lastEdgePreviewSeek = videoSeek;
    if (NativeVideoEngine.instance.isTimelineActive || controller == null) {
      final packed = _sourceToNativePacked(videoSeek);
      unawaited(NativeVideoEngine.instance.seek(packed));
      return;
    }
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
    if (project == null || (controller == null && !_ffmpegPlayback)) {
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

    final musicPath = MusicStorageService.musicPath(project.projectDir, music);
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
    if (_transportPlaying) {
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
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    final playhead = _playhead;
    final music = musicClipAtTime(project.musicTracks, playhead);
    if (music?.id != _syncedMusicId) {
      await _syncMusicPlayback();
      return;
    }
    if (music == null) return;

    final localOffset = playhead - music.timelineStart;
    await _musicPlayer.setVolume(music.volumeAt(localOffset));

    if (!_transportPlaying) return;
    if (_musicPlayer.state != PlayerState.playing) {
      await _syncMusicPlayback();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    final project = _project;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    // Manual transport cancels a bounded transition preview.
    _transitionPreviewUntil = null;
    _transitionPreviewArmed = false;
    _transitionPreviewSeekConfirmed = false;
    _transitionPreviewWindowStart = null;
    _transitionPreviewTimer?.cancel();
    _transitionPreviewTimer = null;
    if (_sequenceTailPlaying) {
      _wantPlayback = false;
      _stopSequenceTail(land: _playhead);
      return;
    }
    // Scrub is the time under the finger. Clearing it first made play read
    // the decoder clock, which was still at the previous position.
    final parked = _scrubPlayhead;
    _scrubPlayhead = null;
    if (NativeVideoEngine.instance.isTimelineActive) {
      if (NativeVideoEngine.instance.isPlaying) {
        _wantPlayback = false;
        unawaited(NativeVideoEngine.instance.pause());
        unawaited(_syncMusicPlayback());
        setState(() {});
        return;
      }
      final desired = parked ?? _playhead;
      final seqEnd = _sequenceDuration;
      final videoEnd = exportTimelineDuration(project.segments);
      // Multi-source playhead is packed sequence time; segment in/out are
      // per-asset locals. isInKeptRegion would miss and snap to clip 0.
      // Clamp to sequence (video ∪ music ∪ text), not picture-only duration.
      final start = _usesPackedPlayhead
          ? (desired >= seqEnd && seqEnd > Duration.zero
                ? Duration.zero
                : clampDuration(desired, Duration.zero, seqEnd))
          : (isInKeptRegion(project.segments, desired)
                ? desired
                : (segmentAt(project.segments, desired)?.start ??
                      project.segments.first.start));
      // Music/text-only region: native clock stops at picture — wall-clock tail.
      if (start >= videoEnd && seqEnd > videoEnd) {
        _wantPlayback = true;
        final nativeLand = videoEnd > Duration.zero
            ? videoEnd - const Duration(milliseconds: 1)
            : Duration.zero;
        unawaited(() async {
          await NativeVideoEngine.instance.seek(
            _sourceToNativePacked(nativeLand),
          );
          if (!mounted) return;
          _tryStartSequenceTail(from: start);
        }());
        return;
      }
      _wantPlayback = true;
      // Always seek to the scrubbed time, then play. The clock can already
      // show that time while the decoder is still on the previous frame.
      final packed = _sourceToNativePacked(start);
      setState(() {});
      unawaited(() async {
        await NativeVideoEngine.instance.seek(packed, resume: true);
        if (!mounted) return;
        await _syncMusicPlayback();
        if (mounted) setState(() {});
      }());
      return;
    }
    if (controller == null) return;
    if (controller.value.isPlaying) {
      _wantPlayback = false;
      controller.pause();
      unawaited(_auxController?.pause() ?? Future<void>.value());
    } else {
      final desired = parked ?? _playhead;
      final videoEnd = exportTimelineDuration(project.segments);
      final seqEnd = _sequenceDuration;
      // Already in the music/text-only black tail — resume wall clock there.
      if (desired >= videoEnd && seqEnd > videoEnd) {
        final from = desired >= seqEnd ? videoEnd : desired;
        _wantPlayback = true;
        _tryStartSequenceTail(from: from);
        return;
      }
      _wantPlayback = true;
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
      if (fade != null &&
          NativeVideoEngine.supports(fade.outgoing.transition)) {
        unawaited(_showSpatialPreviewAt(fade, playing: true));
      } else if (fade != null) {
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
    AnalyticsService.instance.log('music_added');
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

  void _cancelVoiceTimers() {
    _voiceCountdownTimer?.cancel();
    _voiceCountdownTimer = null;
    _voiceTickTimer?.cancel();
    _voiceTickTimer = null;
  }

  Future<void> _pauseTransportForVoice() async {
    if (NativeVideoEngine.instance.isTimelineActive) {
      await NativeVideoEngine.instance.pause();
    }
    await _controller?.pause();
    await _auxController?.pause();
    await _musicSafe(_musicPlayer.pause);
    if (mounted) setState(() {});
  }

  /// Toolbar mic: show start-recording control immediately.
  Future<void> _onVoiceRecordPressed() async {
    if (_exporting || _appendingMedia || _voiceBusy) return;
    if (_voicePhase != _VoiceRecordPhase.idle) {
      await _cancelVoiceFlow();
      return;
    }

    final allowed = await _voiceRecorder.ensurePermission();
    if (!mounted) return;
    if (!allowed) {
      _showSnack(context.l10n.voiceRecordPermissionDenied);
      return;
    }

    await _pauseTransportForVoice();
    if (!mounted) return;
    setState(() => _voicePhase = _VoiceRecordPhase.armed);
  }

  Future<void> _cancelVoiceFlow({bool discardDraft = true}) async {
    _cancelVoiceTimers();
    final draftId = _voiceDraftId;
    _voiceDraftId = null;
    _voiceTimelineStart = null;
    _voiceStartedAt = null;
    _voiceCountdown = 0;
    _voiceBusy = false;
    try {
      await _voiceRecorder.cancel();
    } catch (_) {}

    if (discardDraft && draftId != null) {
      final project = _project;
      if (project != null) {
        project.musicTracks.removeWhere((m) => m.id == draftId);
        final compacted = compactMusicLanes(project.musicTracks);
        project.musicTracks
          ..clear()
          ..addAll(compacted);
        if (_selectedMusicId == draftId) _selectedMusicId = null;
      }
    }
    if (mounted) {
      setState(() => _voicePhase = _VoiceRecordPhase.idle);
    } else {
      _voicePhase = _VoiceRecordPhase.idle;
    }
  }

  Future<void> _onVoicePrimaryPressed() async {
    if (_voiceBusy) return;
    switch (_voicePhase) {
      case _VoiceRecordPhase.armed:
        await _beginVoiceCountdown();
      case _VoiceRecordPhase.recording:
        await _stopVoiceRecording();
      case _VoiceRecordPhase.idle:
      case _VoiceRecordPhase.countdown:
        break;
    }
  }

  Future<void> _beginVoiceCountdown() async {
    if (_voicePhase != _VoiceRecordPhase.armed) return;
    await _pauseTransportForVoice();
    if (!mounted) return;
    setState(() {
      _voicePhase = _VoiceRecordPhase.countdown;
      _voiceCountdown = 3;
    });
    _voiceCountdownTimer?.cancel();
    _voiceCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_voicePhase != _VoiceRecordPhase.countdown) {
        timer.cancel();
        return;
      }
      if (_voiceCountdown <= 1) {
        timer.cancel();
        unawaited(_startVoiceRecording());
        return;
      }
      setState(() => _voiceCountdown -= 1);
    });
  }

  Future<void> _startVoiceRecording() async {
    final project = _project;
    if (project == null || _voiceBusy) return;
    _voiceBusy = true;
    try {
      await _pauseTransportForVoice();
      final path = await _voiceRecorder.start();
      if (!mounted) {
        await _voiceRecorder.cancel();
        return;
      }

      final start = _playhead < Duration.zero ? Duration.zero : _playhead;
      final draftId = const Uuid().v4();
      final draft = ProjectMusic(
        id: draftId,
        title: context.l10n.voiceRecordingTitle,
        fileName: p.basename(path),
        fileDuration: const Duration(milliseconds: 100),
        clipDuration: const Duration(milliseconds: 100),
        timelineStart: start,
        volume: 1.0,
        source: MusicSource.local,
      );

      _history.record(_snapshot());
      final placed = assignMusicLane(project.musicTracks, draft);
      project.musicTracks.add(placed);
      final compacted = compactMusicLanes(project.musicTracks);
      project.musicTracks
        ..clear()
        ..addAll(compacted);

      _voiceDraftId = placed.id;
      _voiceTimelineStart = start;
      _voiceStartedAt = DateTime.now();
      setState(() {
        _voicePhase = _VoiceRecordPhase.recording;
        _selectedMusicId = placed.id;
        _selectedOverlayId = null;
        _selectedSegmentId = null;
        _selectedTransitionAfterIndex = null;
      });

      _voiceTickTimer?.cancel();
      _voiceTickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        _onVoiceRecordTick();
      });
      AnalyticsService.instance.log('voice_record_started');
    } catch (e, st) {
      await _cancelVoiceFlow();
      if (mounted) {
        showLoggedSnackBar(
          context,
          context.l10n.voiceRecordFailed,
          error: e,
          stackTrace: st,
        );
      }
    } finally {
      _voiceBusy = false;
    }
  }

  void _onVoiceRecordTick() {
    if (!mounted || _voicePhase != _VoiceRecordPhase.recording) return;
    final project = _project;
    final draftId = _voiceDraftId;
    final start = _voiceTimelineStart;
    final begun = _voiceStartedAt;
    if (project == null || draftId == null || start == null || begun == null) {
      return;
    }

    var elapsed = DateTime.now().difference(begun);
    if (elapsed < const Duration(milliseconds: 100)) {
      elapsed = const Duration(milliseconds: 100);
    }

    final i = project.musicTracks.indexWhere((m) => m.id == draftId);
    if (i < 0) return;
    final next = project.musicTracks[i].copyWith(
      clipDuration: elapsed,
      fileDuration: elapsed,
    );
    project.musicTracks[i] = next;

    final playhead = start + elapsed;
    setState(() {
      _scrubPlayhead = playhead;
    });
    _seek(playhead, seekVideo: true);
  }

  Future<void> _stopVoiceRecording() async {
    if (_voicePhase != _VoiceRecordPhase.recording || _voiceBusy) return;
    final project = _project;
    final draftId = _voiceDraftId;
    final start = _voiceTimelineStart;
    final begun = _voiceStartedAt;
    if (project == null || draftId == null || start == null || begun == null) {
      await _cancelVoiceFlow();
      return;
    }

    _voiceBusy = true;
    _cancelVoiceTimers();
    try {
      final recordedPath = await _voiceRecorder.stop();
      final wallElapsed = DateTime.now().difference(begun);
      if (recordedPath == null ||
          wallElapsed < const Duration(milliseconds: 250)) {
        await _cancelVoiceFlow();
        if (mounted) _showSnack(context.l10n.voiceRecordTooShort);
        return;
      }

      final dir = await _projectStorage.projectDirectory(project.id);
      if (!mounted) return;
      final title = context.l10n.voiceRecordingTitle;
      final imported = await _musicStorage.importRecording(
        projectDir: dir.path,
        recordedPath: recordedPath,
        title: title,
        timelineStart: start,
        duration: wallElapsed,
      );

      // Keep the same clip id / lane so the live bar becomes the final take.
      final i = project.musicTracks.indexWhere((m) => m.id == draftId);
      final lane = i >= 0 ? project.musicTracks[i].lane : 0;
      final clipDur = imported.clipDuration < minMusicClipDuration
          ? minMusicClipDuration
          : imported.clipDuration;
      final committed = ProjectMusic(
        id: draftId,
        title: imported.title,
        fileName: imported.fileName,
        fileDuration: imported.fileDuration ?? clipDur,
        clipDuration: clipDur,
        timelineStart: start,
        volume: 1.0,
        source: MusicSource.local,
        lane: lane,
      );

      if (i >= 0) {
        project.musicTracks[i] = committed;
      } else {
        project.musicTracks.add(committed);
      }
      final compacted = compactMusicLanes(project.musicTracks);
      project.musicTracks
        ..clear()
        ..addAll(compacted);

      _voiceDraftId = null;
      _voiceTimelineStart = null;
      _voiceStartedAt = null;
      setState(() {
        _voicePhase = _VoiceRecordPhase.idle;
        _selectedMusicId = draftId;
      });
      _scheduleSave();
      unawaited(_ensureMusicWaveform(committed));
      await _syncMusicPlayback();
      unawaited(_attachTimelineCompositor(resume: false, seekTo: _playhead));
      AnalyticsService.instance.log('voice_record_committed');

      try {
        await File(recordedPath).delete();
      } catch (_) {}
    } catch (e, st) {
      await _cancelVoiceFlow();
      if (mounted) {
        showLoggedSnackBar(
          context,
          context.l10n.voiceRecordFailed,
          error: e,
          stackTrace: st,
        );
      }
    } finally {
      _voiceBusy = false;
    }
  }

  Future<void> _openTransitionPicker({int? cutIndex}) async {
    final project = _project;
    final l10n = AppLocalizations.of(context);
    if (project == null || _exporting) return;

    final seq = _sequenceDuration;
    if (!hasTransitionTargets(project.segments, sequenceDuration: seq)) {
      showLoggedSnackBar(context, l10n.transitionNeedsCuts);
      return;
    }

    final sequenceTime = _sequenceTimeForSplit(project.segments, _playhead);
    // A tapped transition marker passes its cut. The toolbar button always
    // targets the cut nearest the playhead: the cut edited last stays
    // selected after the studio closes, and reusing it sent the second
    // transition onto the first cut (replacing it) instead of the new one.
    final index =
        cutIndex ??
        nearestCutIndex(project.segments, sequenceTime, sequenceDuration: seq);
    final includeEnd = hasPictureBlackPad(
      segments: project.segments,
      sequenceDuration: seq,
    );
    final maxIndex = includeEnd
        ? project.segments.length - 1
        : project.segments.length - 2;
    if (index < 0 || index > maxIndex) {
      return;
    }

    // Warm the catalog without blocking the dock open.
    unawaited(TransitionCatalogService.instance.ensureInitialized());

    // Open the studio immediately — don't block the first tap on pause/IME.
    _presentStudioDock(() {
      setState(() {
        _selectedTransitionAfterIndex = index;
        _selectedSegmentId = null;
        _selectedOverlayId = null;
        _selectedMusicId = null;
        _editingOverlayId = null;
        _textStudioOverlayId = null;
        _stickerStudioOpen = false;
        _transitionStudioCutIndex = index;
        _panelPreviewSourcePos = null;
        _panelPreviewFurthestPos = null;
      });
    });

    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
    if (NativeVideoEngine.instance.isTimelineActive &&
        NativeVideoEngine.instance.isPlaying) {
      unawaited(NativeVideoEngine.instance.pause());
    }
  }

  Future<void> _closeTransitionStudio(String source) async {
    final index = _transitionStudioCutIndex;
    OverlayEventLog.log('Editor', 'closeTransitionStudio', {
      'source': source,
      'cutIndex': index,
    });
    if (index == null) return;

    _logTimeline('close.before');

    // Panel is dock chrome. Preview stays on the timeline session — closing
    // only dismisses the overlay. No tear-down, no restore, no re-seek.
    final land =
        _scrubPlayhead ??
        _panelPreviewFurthestPos ??
        _panelPreviewSourcePos ??
        (NativeVideoEngine.instance.isTimelineActive
            ? _nativePackedToSource(NativeVideoEngine.instance.position)
            : _playhead);

    _transitionPreviewGen++;
    _transitionPreviewTimer?.cancel();
    _transitionPreviewTimer = null;
    _transitionPreviewUntil = null;
    _transitionPreviewArmed = false;
    _transitionPreviewSeekConfirmed = false;
    _transitionPreviewWindowStart = null;

    await _dismissStudioDock(() {
      if (!mounted) return;
      setState(() {
        _transitionStudioCutIndex = null;
        _selectedTransitionAfterIndex = null;
      });
    });

    _panelPreviewSourcePos = null;
    _panelPreviewFurthestPos = null;
    _pendingTimelineSeek = null;
    _scrubPlayhead = land;
    _activeFade = null;
    _clearFadeProgress();
    _fadeAnchoredAfterIndex = null;

    try {
      await NativeVideoEngine.instance.pause();
      await _controller?.pause();
      await _auxController?.pause();
    } catch (_) {}

    unawaited(_syncMusicPlayback());
    _logTimeline('close.done', land: land);
    if (mounted) setState(() {});
  }

  void _applyTransitionAtCut(int index, AppliedTransition applied) {
    if (!mounted) return;
    if (!applied.isNone) {
      AnalyticsService.instance.log('transition_applied', {
        'id': applied.id,
        'accessTier':
            TransitionCatalogService.instance
                .itemById(applied.id)
                ?.accessTier
                .name ??
            'free',
        'premium':
            TransitionCatalogService.instance.itemById(applied.id)?.premium ??
            false,
      });
    }
    _mutate((p) {
      final seq = projectSequenceDuration(
        segments: p.segments,
        sourceDuration: p.duration,
        musicTracks: p.musicTracks,
        overlays: p.overlays,
      );
      final includeEnd = hasPictureBlackPad(
        segments: p.segments,
        sequenceDuration: seq,
      );
      final maxIndex = includeEnd
          ? p.segments.length - 1
          : p.segments.length - 2;
      if (index < 0 || index > maxIndex) return;
      final segment = p.segments[index];
      if (applied.isNone) {
        p.segments[index] = segment.copyWith(clearTransition: true);
      } else {
        final next = isEndCutIndex(p.segments, index)
            ? syntheticBlackPadSegment(
                blackPadDuration(segments: p.segments, sequenceDuration: seq),
              )
            : p.segments[index + 1];
        final clamped = clampedTransitionDuration(
          segment.copyWith(transition: applied),
          next: next,
        );
        p.segments[index] = segment.copyWith(
          transition: applied.copyWith(
            duration: clamped <= Duration.zero ? applied.duration : clamped,
          ),
        );
      }
    });
    final stored = _project?.segments[index];
    debugPrint(
      '[TL] apply cut=$index id=${applied.id} '
      'appliedDur=${applied.duration.inMilliseconds}ms '
      'storedDur=${stored?.transitionDuration.inMilliseconds}ms',
    );
    // #region agent log
    debugAgentLog(
      'editor_screen.dart:_applyTransitionAtCut',
      'apply',
      hypothesisId: 'C',
      data: {
        'cut': index,
        'id': applied.id,
        'durMs': applied.duration.inMilliseconds,
        'storedMs': stored?.transitionDuration.inMilliseconds,
        'isNone': applied.isNone,
        'nativePosMs': NativeVideoEngine.instance.position.inMilliseconds,
        'timelineActive': NativeVideoEngine.instance.isTimelineActive,
      },
    );
    // #endregion
    _logTimeline('apply');
    setState(() {
      _selectedTransitionAfterIndex = applied.isNone ? null : index;
    });
    if (applied.isNone) {
      // Clear the effect, then play the hard cut so the user can compare.
      unawaited(_tearDownFadePreview());
      unawaited(_previewTransitionAtCut(index));
      return;
    }
    unawaited(_previewTransitionAtCut(index));
  }

  void _onTransitionDurationChanged(int index, Duration duration) {
    if (!mounted) return;
    final project = _project;
    if (project == null) return;
    final seq = _sequenceDuration;
    final includeEnd = hasPictureBlackPad(
      segments: project.segments,
      sequenceDuration: seq,
    );
    final maxIndex = includeEnd
        ? project.segments.length - 1
        : project.segments.length - 2;
    if (index < 0 || index > maxIndex) return;
    final segment = project.segments[index];
    if (!segment.hasTransition) return;
    final nextSeg = isEndCutIndex(project.segments, index)
        ? syntheticBlackPadSegment(
            blackPadDuration(segments: project.segments, sequenceDuration: seq),
          )
        : project.segments[index + 1];
    final tentative = segment.copyWith(
      transition: segment.transition!.copyWith(duration: duration),
    );
    final clamped = clampedTransitionDuration(tentative, next: nextSeg);
    final applied = clamped <= Duration.zero ? duration : clamped;
    project.segments[index] = segment.copyWith(
      transition: segment.transition!.copyWith(duration: applied),
    );
    debugPrint(
      '[TL] duration.change cut=$index '
      'requested=${duration.inMilliseconds}ms '
      'clamped=${applied.inMilliseconds}ms '
      'segDur=${segment.duration.inMilliseconds}ms '
      'nextDur=${nextSeg.duration.inMilliseconds}ms '
      'stored=${project.segments[index].transitionDuration.inMilliseconds}ms',
    );
    _logTimeline('duration.change');
    _timelineSig = '';
    setState(() {});
    _scheduleSave();
  }

  void _onTransitionParametersChanged(
    int index,
    Map<String, double> parameters,
  ) {
    if (!mounted) return;
    final project = _project;
    if (project == null) return;
    final includeEnd = hasPictureBlackPad(
      segments: project.segments,
      sequenceDuration: _sequenceDuration,
    );
    final maxIndex = includeEnd
        ? project.segments.length - 1
        : project.segments.length - 2;
    if (index < 0 || index > maxIndex) return;
    final segment = project.segments[index];
    if (!segment.hasTransition) return;
    project.segments[index] = segment.copyWith(
      transition: segment.transition!.copyWith(parameters: parameters),
    );
    _scheduleSave();
  }

  /// Arm preview stop at [until]. Wall-clock fallback is only for the
  /// dual-player path — timeline preview stops on native position alone so a
  /// slow compositor cannot cut the effect short.
  ///
  /// Call only after seek+play have started. Arming before seek made the
  /// wall-clock fire while still on the window start frame.
  void _armTransitionPreviewStop(
    int gen,
    Duration until, {
    Duration? wallClockFallback,
    Duration? windowStart,
  }) {
    _transitionPreviewTimer?.cancel();
    _transitionPreviewTimer = null;
    _transitionPreviewUntil = until;
    _transitionPreviewWindowStart = windowStart;
    _transitionPreviewSeekConfirmed = false;
    _transitionPreviewArmed = true;
    if (wallClockFallback == null) return;
    _transitionPreviewTimer = Timer(wallClockFallback, () {
      if (!mounted || gen != _transitionPreviewGen) return;
      debugPrint(
        '[TL] panel.stop reason=wallClock '
        'until=${until.inMilliseconds}ms '
        'fallback=${wallClockFallback.inMilliseconds}ms',
      );
      unawaited(_stopTransitionPreview(reason: 'wallClock'));
    });
  }

  Future<void> _stopTransitionPreview({String reason = 'unspecified'}) async {
    _transitionPreviewTimer?.cancel();
    _transitionPreviewTimer = null;
    final until = _transitionPreviewUntil;
    _transitionPreviewUntil = null;
    _transitionPreviewArmed = false;
    _transitionPreviewSeekConfirmed = false;
    _transitionPreviewWindowStart = null;

    // Prefer the preview end, then furthest reached — never a stale 0 sample.
    final land =
        until ??
        _panelPreviewFurthestPos ??
        (NativeVideoEngine.instance.isTimelineActive
            ? _nativePackedToSource(NativeVideoEngine.instance.position)
            : _controller?.value.position) ??
        Duration.zero;
    if (land > Duration.zero || until != null) {
      _scrubPlayhead = land;
      _panelPreviewSourcePos = land;
      if (_panelPreviewFurthestPos == null ||
          land > _panelPreviewFurthestPos!) {
        _panelPreviewFurthestPos = land;
      }
    }

    // Freeze dual-layer compositor on the completed frame (fully B).
    final active = _activeFade;
    if (active != null && active.td > Duration.zero) {
      _setFadeProgress(1.0, playing: false);
      final half = transitionHalfMs(active.td);
      final auxEnd = active.incoming.start + Duration(milliseconds: half.after);
      final auxTarget = auxEnd > active.incoming.end
          ? active.incoming.end
          : auxEnd;
      try {
        await _controller?.pause();
        await _auxController?.pause();
        // At t=1 only the incoming slot is visible — pin it to the end frame.
        if (_auxController != null && _auxController!.value.isInitialized) {
          await _auxController!.seekTo(auxTarget);
        }
      } catch (_) {}
    } else {
      try {
        await _controller?.pause();
        await _auxController?.pause();
      } catch (_) {}
    }

    debugPrint(
      '[TL] panel.stop pause reason=$reason '
      'until=${until?.inMilliseconds}ms '
      'land=${land.inMilliseconds}ms '
      'nativePos=${NativeVideoEngine.instance.position.inMilliseconds}ms '
      'playing=${NativeVideoEngine.instance.isPlaying}',
    );
    await NativeVideoEngine.instance.pause();
    // Timeline path: already on the end frame — do not seek/preroll. A second
    // seek often lands on an earlier keyframe and looks like a jump to start.
    unawaited(_syncMusicPlayback());
    if (mounted) setState(() {});
  }

  /// Play the cut window on the existing timeline compositor. Panel is dock
  /// chrome only — never prepareTransition (that forced a restore seek on close).
  Future<void> _previewTransitionAtCut(int cutIndex) async {
    final controller = _controller;
    final project = _project;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;
    final seq = _sequenceDuration;
    final includeEnd = hasPictureBlackPad(
      segments: project.segments,
      sequenceDuration: seq,
    );
    final maxIndex = includeEnd
        ? project.segments.length - 1
        : project.segments.length - 2;
    if (cutIndex < 0 || cutIndex > maxIndex) return;

    final gen = ++_transitionPreviewGen;
    final outgoing = project.segments[cutIndex];
    final endCut = isEndCutIndex(project.segments, cutIndex);
    final incoming = endCut
        ? syntheticBlackPadSegment(
            blackPadDuration(segments: project.segments, sequenceDuration: seq),
          )
        : project.segments[cutIndex + 1];
    final td = clampedTransitionDuration(outgoing, next: incoming);
    final hardCut = !outgoing.hasTransition || td <= Duration.zero;
    const hardCutPad = Duration(milliseconds: 500);
    // Packed cut time — segment start/end are per-asset locals and must not be
    // used as the native/UI playhead (photo after video would seek to ~0–3s).
    final cutAt = cutExportTimeAfter(project.segments, cutIndex);
    final half = transitionHalfMs(td);
    final windowBefore = hardCut
        ? hardCutPad
        : Duration(milliseconds: half.before);
    final windowAfter = hardCut
        ? hardCutPad
        : Duration(milliseconds: half.after);
    final outgoingPackedStart = cutAt - outgoing.duration;
    var clampedStart = cutAt - windowBefore;
    if (clampedStart < outgoingPackedStart) {
      clampedStart = outgoingPackedStart;
    }
    if (clampedStart < Duration.zero) clampedStart = Duration.zero;
    final incomingPackedEnd = cutAt + incoming.duration;
    final totalPacked = endCut ? seq : exportTimelineDuration(project.segments);
    var previewUntil = cutAt + windowAfter;
    if (previewUntil > incomingPackedEnd) previewUntil = incomingPackedEnd;
    if (previewUntil > totalPacked) previewUntil = totalPacked;
    if (previewUntil <= clampedStart) {
      previewUntil = clampDuration(
        clampedStart + const Duration(milliseconds: 200),
        Duration.zero,
        totalPacked <= Duration.zero
            ? clampedStart + const Duration(milliseconds: 200)
            : totalPacked,
      );
    }

    _transitionPreviewUntil = null;
    _transitionPreviewArmed = false;
    _transitionPreviewSeekConfirmed = false;
    _transitionPreviewWindowStart = null;
    _transitionPreviewTimer?.cancel();
    _panelPreviewSourcePos = clampedStart;
    _panelPreviewFurthestPos = clampedStart;
    _scrubPlayhead = clampedStart;
    _pendingTimelineSeek = null;
    debugPrint(
      '[TL] panel.preview cut=$cutIndex '
      'td=${td.inMilliseconds}ms '
      'start=${clampedStart.inMilliseconds}ms '
      'end=${outgoing.end.inMilliseconds}ms '
      'until=${previewUntil.inMilliseconds}ms '
      'storedTd=${outgoing.transitionDuration.inMilliseconds}ms',
    );
    // #region agent log
    debugAgentLog(
      'editor_screen.dart:_previewTransitionAtCut',
      'panel.preview',
      hypothesisId: 'A',
      data: {
        'cut': cutIndex,
        'tdMs': td.inMilliseconds,
        'startMs': clampedStart.inMilliseconds,
        'untilMs': previewUntil.inMilliseconds,
        'effect': outgoing.transitionId,
        'hardCut': hardCut,
        'beforeNativeMs': NativeVideoEngine.instance.position.inMilliseconds,
      },
    );
    // #endregion
    _logTimeline('panel.start', land: clampedStart);

    _fadeSyncGen++;
    _fadeHandoffInFlight = false;
    _activeFade = null;
    _clearFadeProgress();
    _fadeAnchoredAfterIndex = null;
    // Drop any leftover short session from older builds.
    if (_spatialPreviewActive) {
      await _tearDownSpatialPreview();
    }
    final aux = _auxController;
    if (aux != null && aux.value.isInitialized) {
      try {
        await aux.pause();
        await aux.setVolume(0);
      } catch (_) {}
    }
    if (!mounted || gen != _transitionPreviewGen) return;

    if (NativeVideoEngine.instance.isPlatformSupported) {
      // Same composition signature → attach only prerolls. Effect/duration
      // changes already change the signature; clearing it forced a native
      // rebuild every panel pick and hid the real seek-back frame bug.
      await _attachTimelineCompositor(resume: false, seekTo: clampedStart);
      if (!mounted || gen != _transitionPreviewGen) return;
      if (NativeVideoEngine.instance.isTimelineActive) {
        _scrubPlayhead = null;
        debugPrint(
          '[TL] panel.play native cut=$cutIndex '
          'effect=${outgoing.transitionId} '
          'td=${td.inMilliseconds}ms '
          'from=${clampedStart.inMilliseconds}ms '
          'until=${previewUntil.inMilliseconds}ms '
          'nativePos=${NativeVideoEngine.instance.position.inMilliseconds}ms',
        );
        // #region agent log
        debugAgentLog(
          'editor_screen.dart:_previewTransitionAtCut',
          'before.play',
          hypothesisId: 'A,B',
          data: {
            'wantStartMs': clampedStart.inMilliseconds,
            'nativePosMs': NativeVideoEngine.instance.position.inMilliseconds,
            'playing': NativeVideoEngine.instance.isPlaying,
            'deltaMs': (NativeVideoEngine.instance.position - clampedStart)
                .inMilliseconds
                .abs(),
          },
        );
        // #endregion
        await NativeVideoEngine.instance.play();
        // #region agent log
        debugAgentLog(
          'editor_screen.dart:_previewTransitionAtCut',
          'after.play',
          hypothesisId: 'F,G',
          data: {
            'nativePosMs': NativeVideoEngine.instance.position.inMilliseconds,
            'playing': NativeVideoEngine.instance.isPlaying,
            'wantStartMs': clampedStart.inMilliseconds,
            'untilMs': previewUntil.inMilliseconds,
          },
        );
        for (final delayMs in <int>[350, 800, 1400]) {
          unawaited(
            Future<void>.delayed(Duration(milliseconds: delayMs), () {
              if (!mounted || gen != _transitionPreviewGen) return;
              debugAgentLog(
                'editor_screen.dart:_previewTransitionAtCut',
                'play.sample',
                hypothesisId: 'G,I',
                data: {
                  'delayMs': delayMs,
                  'nativePosMs':
                      NativeVideoEngine.instance.position.inMilliseconds,
                  'playing': NativeVideoEngine.instance.isPlaying,
                  'wantStartMs': clampedStart.inMilliseconds,
                  'untilMs': previewUntil.inMilliseconds,
                  'armed': _transitionPreviewArmed,
                },
              );
            }),
          );
        }
        // #endregion
        if (!mounted || gen != _transitionPreviewGen) {
          debugPrint(
            '[TL] panel.play cancelled gen=$gen current=$_transitionPreviewGen pause',
          );
          await NativeVideoEngine.instance.pause();
          return;
        }
        // Arm after play so in-flight position events from the previous
        // playhead (already past until) cannot stop us on the start frame.
        _armTransitionPreviewStop(gen, previewUntil, windowStart: clampedStart);
        unawaited(_syncMusicPlayback());
        _syncVideoAudioVolume();
        if (mounted) setState(() {});
        return;
      }
    }

    if (!hardCut) {
      await _ensureAuxController();
      if (!mounted || gen != _transitionPreviewGen) return;
      final auxPlayer = _auxController;
      if (auxPlayer != null && auxPlayer.value.isInitialized) {
        try {
          await auxPlayer.pause();
          await auxPlayer.seekTo(incoming.start);
        } catch (_) {}
      }
    }
    if (!mounted || gen != _transitionPreviewGen || controller == null) return;
    final length = previewUntil - clampedStart;
    debugPrint(
      '[TL] panel.play controller cut=$cutIndex '
      'effect=${outgoing.transitionId} '
      'from=${clampedStart.inMilliseconds}ms '
      'until=${previewUntil.inMilliseconds}ms',
    );
    await controller.seekTo(clampedStart);
    if (!mounted || gen != _transitionPreviewGen) return;
    _scrubPlayhead = null;
    await controller.play();
    if (!mounted || gen != _transitionPreviewGen) {
      await controller.pause();
      await _auxController?.pause();
      return;
    }
    // Arm after play so wall-clock cannot freeze on the seeked start frame.
    _armTransitionPreviewStop(
      gen,
      previewUntil,
      wallClockFallback: length < Duration.zero ? Duration.zero : length,
      windowStart: clampedStart,
    );
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
    final path = MusicStorageService.musicPath(project.projectDir, music);

    var fileDuration = music.fileDuration;
    if (fileDuration == null || fileDuration <= Duration.zero) {
      fileDuration = await _probe.readDuration(path);
    }

    if (!_musicWaveforms.containsKey(music.fileName)) {
      if (!await File(path).exists()) {
        avEditorLog('music waveform missing file $path');
      } else {
        final wave = await AudioWaveformService.instance.waveformForFile(path);
        if (!mounted) return;
        if (wave != null && wave.peaks.isNotEmpty) {
          if (fileDuration == null || fileDuration <= Duration.zero) {
            fileDuration = wave.duration;
          }
          setState(() => _musicWaveforms[music.fileName] = wave.peaks);
          avEditorLog(
            'music waveform loaded file=${music.fileName} peaks=${wave.peaks.length}',
          );
        } else {
          avEditorLog('music waveform decode empty $path');
        }
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
    // Rebuild native length when music extends past picture (black pad).
    unawaited(_attachTimelineCompositor(resume: false, seekTo: _playhead));
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
    AnalyticsService.instance.log('text_added');
    _placeNewTextOverlay();
  }

  /// Opens the docked sticker panel. Pass [replace] to swap an existing sticker.
  void _openStickerStudio({TextOverlay? replace}) {
    final project = _project;
    if (project == null || _exporting) return;
    if (replace != null && !replace.isSticker) return;
    if (_transportPlaying) {
      if (NativeVideoEngine.instance.isTimelineActive) {
        unawaited(NativeVideoEngine.instance.pause());
      } else {
        unawaited(_controller?.pause());
      }
    }
    _presentStudioDock(() {
      setState(() {
        _stickerStudioOpen = true;
        _stickerReplaceOverlayId = replace?.id;
        if (replace != null) {
          _selectedOverlayId = replace.id;
        }
        _textStudioOverlayId = null;
        _transitionStudioCutIndex = null;
        _editingOverlayId = null;
        _selectedSegmentId = null;
        _selectedMusicId = null;
        _selectedTransitionAfterIndex = null;
      });
    });
  }

  void _closeStickerStudio(String source) {
    OverlayEventLog.log('Editor', 'closeStickerStudio', {'source': source});
    if (!_stickerStudioOpen) return;
    unawaited(
      _dismissStudioDock(() {
        if (!mounted) return;
        setState(() {
          _stickerStudioOpen = false;
          _stickerReplaceOverlayId = null;
        });
      }),
    );
  }

  void _onStickerPicked(GiphyStickerPick pick) {
    // Replace mode only (edit opened the panel). Prefer the sticker currently
    // selected on canvas so retargeting while the panel stays open works.
    final selected = _selectedOverlay;
    final replaceId = _stickerReplaceOverlayId == null
        ? null
        : (selected != null && selected.isSticker
              ? selected.id
              : _stickerReplaceOverlayId);
    if (replaceId != null) {
      AnalyticsService.instance.log('sticker_replaced', {
        'giphyId': pick.sticker.id,
      });
      _replaceStickerOverlay(replaceId, pick);
      return;
    }
    AnalyticsService.instance.log('sticker_added', {
      'giphyId': pick.sticker.id,
    });
    _placeNewStickerOverlay(pick);
  }

  /// Keep replace-target in sync when the user retargets while the panel is open.
  void _retargetStickerStudioIfNeeded(TextOverlay overlay) {
    if (!_stickerStudioOpen || !overlay.isSticker) return;
    _stickerReplaceOverlayId = overlay.id;
  }

  void _replaceStickerOverlay(String id, GiphyStickerPick pick) {
    final project = _project;
    if (project == null) return;
    TextOverlay? existing;
    for (final overlay in project.overlays) {
      if (overlay.id == id) {
        existing = overlay;
        break;
      }
    }
    if (existing == null || !existing.isSticker) {
      _placeNewStickerOverlay(pick);
      return;
    }

    final aspect = pick.sticker.width > 0 && pick.sticker.height > 0
        ? pick.sticker.width / pick.sticker.height
        : 1.0;
    final size = math.max(existing.boxWidth, existing.boxHeight);
    var boxW = size;
    var boxH = size;
    if (aspect >= 1) {
      boxH = (boxW / aspect).clamp(120.0, size);
    } else {
      boxW = (boxH * aspect).clamp(120.0, size);
    }

    _updateOverlay(
      existing.copyWith(
        text: pick.sticker.title,
        boxWidth: boxW,
        boxHeight: boxH,
        stickerLocalPath: pick.relativePath,
        stickerGiphyId: pick.sticker.id,
        stickerPreviewUrl: pick.sticker.previewUrl,
      ),
    );
    if (mounted) setState(() => _selectedOverlayId = id);
  }

  void _placeNewStickerOverlay(GiphyStickerPick pick) {
    final project = _project;
    final controller = _controller;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    if (_transportPlaying) {
      if (NativeVideoEngine.instance.isTimelineActive) {
        unawaited(NativeVideoEngine.instance.pause());
      } else {
        unawaited(controller?.pause());
      }
    }

    final start = _textPlacementSourceTime(project);
    var end = start + const Duration(seconds: 3);
    if (end - start < minOverlayDuration) {
      end = start + minOverlayDuration;
    }

    final aspect = pick.sticker.width > 0 && pick.sticker.height > 0
        ? pick.sticker.width / pick.sticker.height
        : 1.0;
    var boxW = kDefaultStickerBox;
    var boxH = kDefaultStickerBox;
    if (aspect >= 1) {
      boxH = (boxW / aspect).clamp(120.0, kDefaultStickerBox);
    } else {
      boxW = (boxH * aspect).clamp(120.0, kDefaultStickerBox);
    }

    final overlay = TextOverlay(
      text: pick.sticker.title,
      start: start,
      end: end,
      kind: OverlayKind.sticker,
      boxWidth: boxW,
      boxHeight: boxH,
      stickerLocalPath: pick.relativePath,
      stickerGiphyId: pick.sticker.id,
      stickerPreviewUrl: pick.sticker.previewUrl,
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
      _textStudioOverlayId = null;
      _transitionStudioCutIndex = null;
      // Keep sticker studio open so the user can add more.
    });
    if (start != _playhead) {
      _seek(start);
    }
    if (mounted) setState(() {});
  }

  void _placeNewTextOverlay() {
    final project = _project;
    final controller = _controller;
    if (project == null || (controller == null && !_ffmpegPlayback)) return;

    // Hangul hint uses DM Sans + CJK fallback; warm Noto KR for first paint.
    unawaited(OverlayFonts.ensureLoaded(OverlayFonts.defaultId));

    if (_transportPlaying) {
      if (NativeVideoEngine.instance.isTimelineActive) {
        unawaited(NativeVideoEngine.instance.pause());
      } else {
        unawaited(controller?.pause());
      }
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
        _stickerStudioOpen = false;
      });
    });
    unawaited(_requestTextChromeTip());
  }

  /// Placement time for a newly placed text/sticker clip.
  ///
  /// Packed projects use the sequence clock for overlays (same as music). Do
  /// not run source-space [isInKeptRegion] there — at t=0 it looks like a gap
  /// and snaps to `segments.first.start`, seeking the timeline away from the
  /// front. Legacy single-source still snaps out of deleted gaps.
  Duration _textPlacementSourceTime(VideoProject project) {
    final t = _playhead;
    final segments = project.segments;
    if (segments.isEmpty) return t;

    if (_usesPackedPlayhead) {
      final seqEnd = _sequenceDuration;
      if (seqEnd <= Duration.zero) return t;
      return clampDuration(t, Duration.zero, seqEnd);
    }

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
    // Always re-fit: composition packs (Chat Message) need chrome that hugs
    // bubbles, not a full-font multiline measure from an older fit.
    final fitted = fitOverlayBoxToText(
      overlay,
      emptyPlaceholder: context.l10n.textOverlayHint,
    );
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
        _stickerStudioOpen = false;
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

  void _openCanvasRatioMenu() {
    if (_exporting) return;
    setState(() => _canvasRatioOpen = true);
  }

  void _closeCanvasRatioMenu() {
    setState(() => _canvasRatioOpen = false);
  }

  void _selectCanvasRatio(CanvasRatio ratio) {
    final project = _project;
    if (project == null || ratio == project.canvas) return;
    _mutate((p) => p.canvas = ratio);
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
    final newPack = updated.packItemId;
    if (newPack != null && newPack != project.overlays[index].packItemId) {
      AnalyticsService.instance.log('text_style_applied', {
        'id': newPack,
        'accessTier':
            TextTemplatePackService.instance
                .itemById(newPack)
                ?.accessTier
                .name ??
            'free',
        'premium':
            TextTemplatePackService.instance.itemById(newPack)?.premium ??
            false,
      });
    }

    // Stickers keep their own box aspect; text-fit would squash them to the
    // Giphy title string (e.g. timeline trim → 1:1 becomes ~2:1).
    final next = updated.isSticker ? updated : fitOverlayBoxToText(updated);
    setState(() {
      final placed = assignOverlayLane(
        project.overlays,
        next,
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
    if (overlay.isSticker) return;
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
    if (overlay.isSticker) {
      _openStickerStudio(replace: overlay);
      return;
    }
    _openTextStudio(overlay);
  }

  /// Freeze preview + bed music so export (and the sheet before it) is silent.
  Future<void> _pausePlaybackForExport() async {
    if (NativeVideoEngine.instance.isTimelineActive) {
      if (NativeVideoEngine.instance.isPlaying) {
        await NativeVideoEngine.instance.pause();
      }
    } else {
      await _controller?.pause();
      await _auxController?.pause();
    }
    await _musicSafe(_musicPlayer.pause);
    if (mounted) setState(() {});
  }

  Future<void> _presentExport() async {
    final project = _project;
    if (project == null || _exporting) return;
    // Block share immediately so a slow premium sheet can't double-fire.
    setState(() {
      _exporting = true;
      _exportProgress = null;
    });
    AnalyticsService.instance.log('export_tap');
    try {
      if (_inTextStudio) {
        _closeTextStudio('export');
      }
      if (_inStickerStudio) {
        _closeStickerStudio('export');
      }
      if (_transitionStudioCutIndex != null) {
        unawaited(_closeTransitionStudio('export'));
      }
      await _pausePlaybackForExport();
      if (!mounted) return;
      final exportProject = await _resolvePremiumForExport(project);
      if (exportProject == null || !mounted) return;
      await _pausePlaybackForExport();
      if (!mounted) return;

      setState(() => _exportProgress = 0);
      final quality = await _appSettings.getExportQualityProfile();
      final started = DateTime.now();
      AnalyticsService.instance.log('export_started', {
        'quality': quality.name,
      });
      final path = await _exportService.exportToFile(
        exportProject,
        quality: quality,
        onProgress: (value) {
          if (!mounted) return;
          final next = value.clamp(0.0, 1.0);
          final current = _exportProgress ?? 0;
          // Always paint the last stretch — strip/hard-cut exports spend a
          // long time near the end while the muxer finishes.
          if ((next - current).abs() < 0.01 && next < 0.98) return;
          setState(() => _exportProgress = next);
        },
      );
      if (!mounted) return;
      AnalyticsService.instance.log('export_completed', {
        'seconds': DateTime.now().difference(started).inSeconds,
      });
      setState(() => _exportProgress = 1);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ExportShareScreen(
            project: exportProject,
            preparedExportPath: path,
          ),
        ),
      );
    } catch (e, st) {
      avEditorLog('inline export failed: $e');
      debugPrint('$st');
      AnalyticsService.instance.log('export_failed');
      if (mounted) {
        showLoggedSnackBar(
          context,
          context.l10n.exportFailedWithMessage(e.toString()),
          error: e,
          stackTrace: st,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _premiumGateBusy = false;
          _exportProgress = null;
        });
      }
    }
  }

  /// Effects are gated by plan (Plus / Pro) or per-effect ad unlocks.
  /// Credits are reserved for AI. Returns the project to export, or null.
  Future<VideoProject?> _resolvePremiumForExport(VideoProject project) async {
    final pro = ProService.instance;
    await pro.ensureInitialized();
    if (mounted) setState(() => _premiumGateBusy = true);
    try {
      // Fresh catalogs + entitlement before gating (shows progress bar).
      await Future.wait([
        TransitionCatalogService.instance.refresh(awaitRemote: true),
        TextTemplatePackService.instance.refresh(),
        pro.refreshEntitlementFromServer(),
      ]);
    } finally {
      if (mounted) setState(() => _premiumGateBusy = false);
    }
    if (!mounted) return null;
    final unlocks = EffectAdUnlockService.instance;
    // Each save needs its own ads — do not carry unlocks across exports.
    unlocks.clear();

    final catalog = PremiumCatalog.live();
    bool adUnlocked(PremiumUse use) => unlocks.isUnlocked(use);
    final locked = lockedUsesIn(
      project,
      catalog,
      pro.tier,
      isAdUnlocked: adUnlocked,
    );
    debugPrint(
      '[export/premium] tier=${pro.tier.name} locked='
      '${locked.map((u) => '${u.itemId}:${u.accessTier.name}').join(',')}',
    );
    if (locked.isEmpty || !mounted) return project;

    final analytics = AnalyticsService.instance;
    analytics.log('premium_sheet_shown', {
      'items': locked.map((u) => u.itemId).take(10).toList(),
      'tiers': locked.map((u) => u.accessTier.name).take(10).toList(),
      'plan': pro.tier.name,
    });
    final choice = await showPremiumExportSheet(context, uses: locked);
    if (!mounted || choice == null) return null;
    switch (choice) {
      case PremiumExportChoice.subscribe:
        analytics.log('premium_choice_pro');
        final active = await PaywallScreen.open(
          context,
          source: 'export',
          preferAnnual: false,
        );
        if (!active || !mounted) return null;
        // Plus may still be short of Pro effects — only continue when covered.
        if (lockedUsesIn(
          project,
          catalog,
          pro.tier,
          isAdUnlocked: adUnlocked,
        ).isEmpty) {
          return project;
        }
        return null;
      case PremiumExportChoice.continueWithUnlocks:
        analytics.log('premium_choice_ad');
        if (lockedUsesIn(
          project,
          catalog,
          pro.tier,
          isAdUnlocked: adUnlocked,
        ).isEmpty) {
          return project;
        }
        return null;
      case PremiumExportChoice.strip:
        analytics.log('premium_choice_strip');
        return withoutLocked(
          project,
          catalog,
          pro.tier,
          isAdUnlocked: adUnlocked,
        );
    }
  }

  bool _namingProject = false;

  /// "Project N" with the first N not already used by a saved project.
  Future<String> _nextDefaultProjectName() async {
    final l10n = context.l10n;
    final summaries = await _projectStorage.listSummaries();
    final used = summaries
        .map((s) => s.name?.trim())
        .whereType<String>()
        .toSet();
    var n = 1;
    while (used.contains(l10n.projectDefaultName(n))) {
      n++;
    }
    return l10n.projectDefaultName(n);
  }

  /// Name dialog with the field pre-filled and fully selected, so typing
  /// replaces the suggestion in one go. Returns null when cancelled.
  Future<String?> _askProjectName({required String initial}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ProjectNameDialog(initial: initial),
    );
  }

  Future<void> _setProjectName(String name) async {
    final project = _project;
    if (project == null) return;
    setState(() => project.name = name);
    await _persistProject();
  }

  /// Back out of the editor. An unnamed project asks for a name first;
  /// cancelling the dialog keeps the user in the editor.
  Future<void> _handleBack() async {
    if (_exporting) return;
    if (_namingProject) return;
    final project = _project;
    if (project != null && (project.name?.trim().isEmpty ?? true)) {
      _namingProject = true;
      try {
        final suggestion = await _nextDefaultProjectName();
        if (!mounted) return;
        final name = await _askProjectName(initial: suggestion);
        if (!mounted || name == null) return;
        await _setProjectName(name);
      } finally {
        _namingProject = false;
      }
    }
    // Priority 1: unfinished draft → 24h/72h (soft pref prompt is on Home).
    final leaving = _project;
    if (leaving != null && leaving.isDraft && mounted) {
      final l10n = context.l10n;
      unawaited(
        RetentionNotificationService.instance.scheduleDraftAbandon(
          projectId: leaving.id,
          title: l10n.pushDraftTitle,
          body24: l10n.pushDraftBody24,
          body72: l10n.pushDraftBody72,
        ),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _renameProject() async {
    final project = _project;
    if (project == null) return;
    final current = project.name?.trim();
    final name = await _askProjectName(
      initial: (current == null || current.isEmpty)
          ? await _nextDefaultProjectName()
          : current,
    );
    if (!mounted || name == null) return;
    await _setProjectName(name);
  }

  Widget _buildEditorTitle(AppLocalizations l10n, VideoProject project) {
    final name = project.name?.trim();
    if (name == null || name.isEmpty) return Text(l10n.editorTitle);
    // Tap to rename. Multi-line names wrap up to two lines.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _renameProject,
      child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final project = _project;
    final controller = _controller;

    if (!_ready) {
      // Opening: stay transparent so Home remains visible (opaque:false route).
      // Converting (re-encode) still shows progress.
      if (_convertProgress != null) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.editorTitle)),
          body: Center(
            child: ConvertProgressView(
              label: l10n.convertingVideo,
              progress: _convertProgress,
            ),
          ),
        );
      }
      return const AbsorbPointer(
        child: ColoredBox(color: Color(0x00000000), child: SizedBox.expand()),
      );
    }

    if (_errorMessage != null ||
        project == null ||
        (controller == null && !_ffmpegPlayback)) {
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

    // Timeline preview owns canvas size; the hard-cut VideoPlayerController
    // may still be the orphaned first import (wrong aspect after replace).
    final sourceAspect =
        NativeVideoEngine.instance.isTimelineActive &&
            NativeVideoEngine.instance.previewWidth > 0 &&
            NativeVideoEngine.instance.previewHeight > 0
        ? NativeVideoEngine.instance.previewWidth /
              NativeVideoEngine.instance.previewHeight
        : (_sourceAspect > 0
              ? _sourceAspect
              : (controller != null && controller.value.aspectRatio != 0
                    ? controller.value.aspectRatio
                    : 9 / 16));
    final canvasAspect = project.canvas.frameAspect(sourceAspect);
    final inTextStudio = _inTextStudio;
    final studioOverlay = _textStudioOverlay;
    final editingOverlay = _editingOverlay;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        // Text studio is a Stack overlay — preview/timeline layout never reflows.
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 0,
          title: _buildEditorTitle(l10n, project),
          actions: [
            if (inTextStudio)
              TextButton(
                onPressed: _exporting
                    ? null
                    : () => _closeTextStudio('save_button'),
                child: Text(l10n.save),
              )
            else ...[
              IconButton(
                onPressed: !_exporting && _history.canUndo ? _undo : null,
                icon: const Icon(Icons.undo),
                tooltip: l10n.undo,
              ),
              IconButton(
                onPressed: !_exporting && _history.canRedo ? _redo : null,
                icon: const Icon(Icons.redo),
                tooltip: l10n.redo,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FilledButton(
                  onPressed: _exporting ? null : _presentExport,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.surfaceElevated,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  child: Text(
                    l10n.export,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
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
                      child: ColoredBox(
                        color: _previewChromeColor,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final targetWidth = constraints.maxWidth;
                              final targetHeight = targetWidth / canvasAspect;
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
                                      canvasAspect: canvasAspect,
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
                                      _previewKey.currentState
                                          ?.handlePointerDown(e);
                                    },
                                    onPointerMove: (e) => _previewKey
                                        .currentState
                                        ?.handlePointerMove(e),
                                    onPointerUp: (e) => _previewKey.currentState
                                        ?.handlePointerUp(e.pointer),
                                    onPointerCancel: (e) => _previewKey
                                        .currentState
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
                                            alignment: Alignment.center,
                                            child: OverflowSizedBox(
                                              width: targetWidth,
                                              height: targetHeight,
                                              child: AbsorbPointer(
                                                absorbing: _exporting,
                                                // Progress must paint above text/sticker
                                                // overlays — videoChild sits under them.
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    VideoPreviewWithOverlays(
                                                      key: _previewKey,
                                                      videoAspectRatio:
                                                          sourceAspect,
                                                      canvasAspectRatio:
                                                          canvasAspect,
                                                      videoChild: Stack(
                                                        fit: StackFit.expand,
                                                        children: [
                                                          _buildPreviewVideoChild(
                                                            controller,
                                                          ),
                                                          // Music/text past picture → solid black.
                                                          if (_playheadPastPicture)
                                                            const ColoredBox(
                                                              color:
                                                                  Colors.black,
                                                            ),
                                                        ],
                                                      ),
                                                      overlays:
                                                          project.overlays,
                                                      segments:
                                                          project.segments,
                                                      position: _playhead,
                                                      isPlaying:
                                                          _transportPlaying,
                                                      clipRotation:
                                                          project.rotation,
                                                      hostViewportSize: Size(
                                                        constraints.maxWidth,
                                                        constraints.maxHeight,
                                                      ),
                                                      projectDir:
                                                          project.projectDir,
                                                      selectedOverlayId:
                                                          _selectedOverlayId,
                                                      editingOverlayId:
                                                          _editingOverlayId,
                                                      selectAllOnEdit:
                                                          _inlineEditSelectAll,
                                                      textHint:
                                                          l10n.textOverlayHint,
                                                      onOverlaySelected: (overlay) {
                                                        if (_editingOverlayId !=
                                                                null &&
                                                            _editingOverlayId !=
                                                                overlay.id) {
                                                          _finishInlineEditing(
                                                            'select_other_overlay',
                                                          );
                                                        }
                                                        setState(() {
                                                          _selectedOverlayId =
                                                              overlay.id;
                                                          // Keep the studio open; retarget it.
                                                          if (_textStudioOverlayId !=
                                                              null) {
                                                            _textStudioOverlayId =
                                                                overlay.id;
                                                          }
                                                          _retargetStickerStudioIfNeeded(
                                                            overlay,
                                                          );
                                                        });
                                                      },
                                                      onRequestEdit:
                                                          _startInlineEditing,
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
                                                              (
                                                                current,
                                                              ) => current
                                                                  .copyWith(
                                                                    offset:
                                                                        offset,
                                                                  ),
                                                            );
                                                          },
                                                      onOverlayDeleted:
                                                          _deleteOverlayByOverlay,
                                                      onOverlayDuplicated:
                                                          _duplicateOverlay,
                                                      onOverlayEdit: (overlay) {
                                                        setState(() {
                                                          _selectedOverlayId =
                                                              overlay.id;
                                                          _retargetStickerStudioIfNeeded(
                                                            overlay,
                                                          );
                                                        });
                                                        if (overlay.isSticker) {
                                                          _openStickerStudio(
                                                            replace: overlay,
                                                          );
                                                          return;
                                                        }
                                                        _editSelectedOverlay();
                                                      },
                                                      onOverlayBoxChanged: (overlay, transform) {
                                                        OverlayEventLog.log(
                                                          'Editor',
                                                          'overlayBoxChanged',
                                                          {
                                                            'id': overlay.id,
                                                            'width': transform
                                                                .width
                                                                .toStringAsFixed(
                                                                  1,
                                                                ),
                                                            'height': transform
                                                                .height
                                                                .toStringAsFixed(
                                                                  1,
                                                                ),
                                                            'font': transform
                                                                .fontSize
                                                                .toStringAsFixed(
                                                                  1,
                                                                ),
                                                            'offset': transform
                                                                .offset,
                                                            'rotation': transform
                                                                .rotation
                                                                .toStringAsFixed(
                                                                  3,
                                                                ),
                                                          },
                                                        );
                                                        _patchOverlay(
                                                          overlay.id,
                                                          (
                                                            current,
                                                          ) => current.copyWith(
                                                            boxWidth:
                                                                transform.width,
                                                            boxHeight: transform
                                                                .height,
                                                            fontSize: transform
                                                                .fontSize,
                                                            offset: transform
                                                                .offset,
                                                            rotation: transform
                                                                .rotation,
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                    if (_exportProgress != null)
                                                      Positioned.fill(
                                                        child: _ExportPreviewPercent(
                                                          progress:
                                                              _exportProgress!,
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Sit on the preview slot (not the video frame) so
                                  // letterboxing never covers the control.
                                  if (!_canvasRatioOpen && !_exporting)
                                    Positioned(
                                      top: 8,
                                      right: 8,
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
                                        child: _CanvasRatioButton(
                                          label:
                                              project.canvas ==
                                                  CanvasRatio.original
                                              ? l10n.canvasRatioOriginal
                                              : project.canvas.ratioLabel,
                                          onPressed: _exporting
                                              ? null
                                              : _openCanvasRatioMenu,
                                        ),
                                      ),
                                    ),
                                  if (editingOverlay == null)
                                    _buildPreviewDockDragEdge(
                                      zoneHeight: constraints.maxHeight * 0.2,
                                    ),
                                  if (_canvasRatioOpen)
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      right: 0,
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
                                        child: CanvasRatioBar(
                                          selected: project.canvas,
                                          sourceAspect: sourceAspect,
                                          originalLabel:
                                              l10n.canvasRatioOriginal,
                                          onSelected: _selectCanvasRatio,
                                          onClose: _closeCanvasRatioMenu,
                                        ),
                                      ),
                                    ),
                                  ?_buildVoiceRecordOverlay(l10n),
                                ],
                              );
                            },
                          ),
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
                    child: BasicTextEditKeyboardTray(
                      overlay: editingOverlay,
                      onChanged: _updateOverlay,
                      onDismissKeyboard: () =>
                          _finishInlineEditing('keyboard_dismiss'),
                    ),
                  ),
                if (_appendingMedia)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Center(
                        child: ConvertProgressView(
                          label: l10n.convertingVideo,
                          progress: _convertProgress,
                        ),
                      ),
                    ),
                  ),
                if (_coach != _EditorCoachKind.none)
                  Positioned.fill(
                    child: EditorOnboardingOverlay(
                      skipLabel: l10n.onboardingSkip,
                      nextLabel: l10n.onboardingNext,
                      doneLabel: l10n.onboardingDone,
                      onFinished: () => unawaited(_finishCoach()),
                      steps: _coachSteps(l10n),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Bottom dock: timeline chrome, text studio, or transition studio.
  ///
  /// Entry (`_dockHeight == null`) locks to the mid stage. Expanded uses an
  /// explicit height (compact / max ~2/3). `0` hides the dock (full video).
  Widget _buildBottomDock({
    required AppLocalizations l10n,
    required VideoProject project,
    required VideoPlayerController? controller,
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
        // Full-video (and the last stretch of the collapse animation): do not
        // lay out timeline/chips in a sliver shorter than the home indicator —
        // that was overflowing Column by ~20–55px.
        if (h <= 0.5 || h <= safeBottom + 8) {
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
        final seq = _sequenceDuration;
        final includeEndCut = hasPictureBlackPad(
          segments: project.segments,
          sequenceDuration: seq,
        );
        final showTransition =
            cutIndex != null &&
            cutIndex >= 0 &&
            (cutIndex < project.segments.length - 1 ||
                (includeEndCut && cutIndex == project.segments.length - 1));
        final showText = inTextStudio && studioOverlay != null;
        final showSticker = _inStickerStudio;
        final showStudio = showText || showTransition || showSticker;

        Widget? studio;
        if (showSticker) {
          studio = slideInStudio(
            const ValueKey('sticker-studio'),
            GiphyStickerPickerPanel(
              projectDir: project.projectDir,
              onPicked: _onStickerPicked,
              onConfirm: () => _closeStickerStudio('studio_confirm'),
            ),
          );
        } else if (showText) {
          studio = slideInStudio(
            ValueKey('text-studio-${studioOverlay.id}'),
            TapRegion(
              groupId: kBasicTextEditTapGroup,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
                child: TextStudioPanel(
                  key: _textStudioPanelKey,
                  overlay: studioOverlay,
                  onChanged: _updateOverlay,
                  onConfirm: () => _closeTextStudio('studio_confirm'),
                  textTabKey: _onboardTextTabKey,
                  textTemplatesTabKey: _onboardTextTemplatesTabKey,
                ),
              ),
            ),
          );
        } else if (showTransition) {
          final current = project.segments[cutIndex];
          final next = isEndCutIndex(project.segments, cutIndex)
              ? syntheticBlackPadSegment(
                  blackPadDuration(
                    segments: project.segments,
                    sequenceDuration: seq,
                  ),
                )
              : project.segments[cutIndex + 1];
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
                  : const Duration(milliseconds: 500),
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
                  ignoring: showStudio || editingOverlay != null || _exporting,
                  child: _buildCollapsibleChrome(
                    l10n: l10n,
                    project: project,
                    controller: controller,
                    isInlineEditing: _editingOverlayId != null,
                    dockHeight: dockH,
                  ),
                ),
              ),
              if (studio != null) Positioned.fill(child: studio),
              if (_premiumGateBusy)
                const Positioned.fill(child: _ExportGateBusyOverlay()),
              if (_exportProgress != null)
                Positioned.fill(
                  child: _ExportDockBusyOverlay(
                    label: l10n.exporting,
                    progress: _exportProgress!,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCollapsibleChrome({
    required AppLocalizations l10n,
    required VideoProject project,
    required VideoPlayerController? controller,
    required bool isInlineEditing,
    required double? dockHeight,
  }) {
    final hidden = dockHeight != null && dockHeight <= 0.5;

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
    // Compact keeps tool chips; while collapsing to full-video, drop chips
    // before the Column overflows.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxH = constraints.maxHeight;
        if (maxH < 56) {
          return const SizedBox.expand();
        }
        // Transport + skimpy strip ≈ 56; chips ≈ 56 + gap.
        final showActions = maxH >= 130;
        return Column(
          children: [
            Expanded(child: timeline),
            if (showActions) ...[const SizedBox(height: 8), actions],
          ],
        );
      },
    );
  }

  Widget _buildTimeline({
    required VideoProject project,
    required VideoPlayerController? controller,
    bool expandToFill = false,
  }) {
    return KeyedSubtree(
      key: _onboardTimelineKey,
      child: TimelineWidget(
      key: _timelineKey,
      duration: project.duration,
      trimStart: project.trim.start,
      trimEnd: project.trim.end,
      segments: project.segments,
      mediaAssets: project.mediaAssets,
      overlays: project.overlays,
      musicTracks: project.musicTracks,
      musicWaveforms: _musicWaveforms,
      sourceAudioWaveforms: _sourceAudioWaveforms,
      sourceAudioDurations: _sourceAudioDurations,
      hasSourceAudio: _hasSourceAudio,
      filmstripFrames: _filmstripFrames,
      playhead: _timelinePlayhead,
      isPlaying: _transportPlaying,
      onTogglePlay: _togglePlay,
      onHandleDragUpdate: _onChromeDragUpdate,
      onHandleDragEnd: _onChromeDragEnd,
      expandToFill: expandToFill,
      onAddMedia: _appendingMedia || _exporting ? null : _addTimelineMedia,
      addMediaTooltip: context.l10n.addTimelineMedia,
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
          _retargetStickerStudioIfNeeded(overlay);
        });
      },
      onMusicChanged: _replaceMusicClip,
      onSegmentChanged: (segment) {
        _mutate((p) {
          final i = p.segments.indexWhere((s) => s.id == segment.id);
          if (i >= 0) p.segments[i] = segment;
          _syncPackedDuration(p);
        });
        _syncVideoAudioVolume();
        // Packed edge preview/rebuild is driven by [onEdgeFramePreview] after
        // this mutation so seeks use the already-dragged duration.
      },
      onSegmentsReordered: (segments) {
        _mutate((p) {
          p.segments
            ..clear()
            ..addAll(segments);
          _selectedTransitionAfterIndex = null;
          _syncPackedDuration(p);
        });
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
      onSelectionCleared: () {
        if (_selectedOverlayId == null &&
            _selectedSegmentId == null &&
            _selectedMusicId == null &&
            _selectedTransitionAfterIndex == null) {
          return;
        }
        setState(() {
          _selectedOverlayId = null;
          _selectedSegmentId = null;
          _selectedMusicId = null;
          _selectedTransitionAfterIndex = null;
        });
      },
    ),
    );
  }

  List<EditorOnboardingStep> _coachSteps(AppLocalizations l10n) {
    return switch (_coach) {
      _EditorCoachKind.firstRun => [
          EditorOnboardingStep(
            targetKey: _onboardSplitKey,
            title: l10n.onboardingSplitTitle,
            body: l10n.onboardingSplitBody,
          ),
          // Transition tip is shown after the first cut (splitTransition), not here.
          EditorOnboardingStep(
            targetKey: _onboardTextKey,
            title: l10n.onboardingTextTitle,
            body: l10n.onboardingTextBody,
          ),
          EditorOnboardingStep(
            targetKey: _onboardDockKey,
            title: l10n.onboardingDockTitle,
            body: l10n.onboardingDockBody,
          ),
        ],
      _EditorCoachKind.splitTransition => [
          EditorOnboardingStep(
            resolveHole: _firstCutMarkerHole,
            title: l10n.onboardingCutTransitionTitle,
            body: l10n.onboardingCutTransitionBody,
          ),
        ],
      _EditorCoachKind.splitReorder => [
          EditorOnboardingStep(
            targetKey: _onboardTimelineKey,
            title: l10n.onboardingReorderTitle,
            body: l10n.onboardingReorderBody,
          ),
        ],
      _EditorCoachKind.textChrome => [
          EditorOnboardingStep(
            resolveHole: (box) =>
                _chromeKnobHole(box, OverlayChromeKnobKind.delete),
            title: l10n.onboardingTextDeleteTitle,
            body: l10n.onboardingTextDeleteBody,
          ),
          EditorOnboardingStep(
            resolveHole: (box) =>
                _chromeKnobHole(box, OverlayChromeKnobKind.edit),
            title: l10n.onboardingTextEditTitle,
            body: l10n.onboardingTextEditBody,
          ),
          EditorOnboardingStep(
            resolveHole: (box) =>
                _chromeKnobHole(box, OverlayChromeKnobKind.duplicate),
            title: l10n.onboardingTextDuplicateTitle,
            body: l10n.onboardingTextDuplicateBody,
          ),
          EditorOnboardingStep(
            resolveHole: (box) =>
                _chromeKnobHole(box, OverlayChromeKnobKind.resizeRotate),
            title: l10n.onboardingTextResizeTitle,
            body: l10n.onboardingTextResizeBody,
          ),
          EditorOnboardingStep(
            targetKey: _onboardTextTabKey,
            onEnter: () =>
                _textStudioPanelKey.currentState?.selectTab(TextStudioTab.templates),
            title: l10n.onboardingTextStudioTextTitle,
            body: l10n.onboardingTextStudioTextBody,
          ),
          EditorOnboardingStep(
            targetKey: _onboardTextTemplatesTabKey,
            onEnter: () => _textStudioPanelKey.currentState
                ?.selectTab(TextStudioTab.textTemplates),
            title: l10n.onboardingTextStudioTemplatesTitle,
            body: l10n.onboardingTextStudioTemplatesBody,
          ),
        ],
      _EditorCoachKind.none => const [],
    };
  }

  Rect? _firstCutMarkerHole(RenderBox overlayBox) {
    return _timelineKey.currentState?.firstCutMarkerRectIn(overlayBox);
  }

  Rect? _chromeKnobHole(RenderBox overlayBox, OverlayChromeKnobKind kind) {
    return _previewKey.currentState?.chromeKnobRectIn(
      overlayBox,
      kind: kind,
    );
  }

  Future<void> _maybeStartOnboarding() async {
    if (_errorMessage != null) return;
    final seen = await const AppSettingsService().hasSeenEditorOnboarding();
    if (seen || !mounted) return;
    // Let the dock / tools settle after first layout.
    await Future<void>.delayed(const Duration(milliseconds: 480));
    if (!mounted ||
        _exporting ||
        _errorMessage != null ||
        _coach != _EditorCoachKind.none) {
      return;
    }
    setState(() => _coach = _EditorCoachKind.firstRun);
  }

  Future<void> _requestSplitTransitionTip() async {
    final settings = const AppSettingsService();
    if (await settings.hasSeenSplitTransitionTip()) {
      unawaited(_requestSplitReorderTip());
      return;
    }
    if (!mounted) return;
    if (_coach == _EditorCoachKind.firstRun ||
        _coach == _EditorCoachKind.textChrome) {
      _pendingSplitTransitionTip = true;
      return;
    }
    if (_coach != _EditorCoachKind.none || _exporting) return;
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (!mounted ||
        _coach != _EditorCoachKind.none ||
        _exporting ||
        await settings.hasSeenSplitTransitionTip()) {
      return;
    }
    // Selected clips hide adjacent cut chips — clear so the tip can spotlight.
    setState(() {
      _selectedSegmentId = null;
      _coach = _EditorCoachKind.splitTransition;
    });
  }

  Future<void> _requestSplitReorderTip() async {
    final settings = const AppSettingsService();
    if (await settings.hasSeenSplitReorderTip()) return;
    if (!mounted) return;
    if (_coach == _EditorCoachKind.firstRun ||
        _coach == _EditorCoachKind.splitTransition ||
        _coach == _EditorCoachKind.textChrome) {
      _pendingSplitReorderTip = true;
      return;
    }
    if (_coach != _EditorCoachKind.none || _exporting) return;
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted ||
        _coach != _EditorCoachKind.none ||
        _exporting ||
        await settings.hasSeenSplitReorderTip()) {
      return;
    }
    setState(() => _coach = _EditorCoachKind.splitReorder);
  }

  Future<void> _requestTextChromeTip() async {
    final settings = const AppSettingsService();
    if (await settings.hasSeenTextChromeTip()) return;
    if (!mounted) return;
    if (_coach != _EditorCoachKind.none) {
      _pendingTextChromeTip = true;
      return;
    }
    if (_exporting) return;
    // Let the new overlay + chrome layout settle (studio may still be rising).
    await Future<void>.delayed(const Duration(milliseconds: 520));
    if (!mounted ||
        _coach != _EditorCoachKind.none ||
        _exporting ||
        await settings.hasSeenTextChromeTip()) {
      return;
    }
    // Corner knobs hide while inline-editing — keep selection only.
    setState(() {
      _editingOverlayId = null;
      _coach = _EditorCoachKind.textChrome;
    });
  }

  Future<void> _finishCoach() async {
    final settings = const AppSettingsService();
    final kind = _coach;
    switch (kind) {
      case _EditorCoachKind.firstRun:
        await settings.setSeenEditorOnboarding(true);
      case _EditorCoachKind.splitTransition:
        await settings.setSeenSplitTransitionTip(true);
      case _EditorCoachKind.splitReorder:
        await settings.setSeenSplitReorderTip(true);
      case _EditorCoachKind.textChrome:
        await settings.setSeenTextChromeTip(true);
      case _EditorCoachKind.none:
        break;
    }
    if (!mounted) return;
    setState(() => _coach = _EditorCoachKind.none);
    if (_pendingSplitTransitionTip) {
      _pendingSplitTransitionTip = false;
      unawaited(_requestSplitTransitionTip());
      return;
    }
    if (kind == _EditorCoachKind.splitTransition || _pendingSplitReorderTip) {
      _pendingSplitReorderTip = false;
      unawaited(_requestSplitReorderTip());
      return;
    }
    if (_pendingTextChromeTip) {
      _pendingTextChromeTip = false;
      unawaited(_requestTextChromeTip());
    }
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
                KeyedSubtree(
                  key: _onboardTextKey,
                  child: IconButton.outlined(
                    onPressed: _exporting ? null : _addTextOverlay,
                    icon: _TextAddIcon(enabled: !_exporting, sparkle: true),
                    tooltip: l10n.addText,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting ? null : _openStickerStudio,
                  icon: const Icon(Icons.sticky_note_2_outlined),
                  tooltip: l10n.addSticker,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting || _selectedOverlay == null
                      ? null
                      : _editSelectedOverlay,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: l10n.editText,
                ),
                const SizedBox(width: 8),
                KeyedSubtree(
                  key: _onboardSplitKey,
                  child: IconButton.outlined(
                    onPressed: _exporting ? null : _splitAtPlayhead,
                    icon: const Icon(Icons.content_cut),
                    tooltip: l10n.splitVideo,
                  ),
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
                  onPressed: _exporting || _voicePhase != _VoiceRecordPhase.idle
                      ? null
                      : _openMusicPicker,
                  icon: const Icon(Icons.music_note),
                  tooltip: l10n.addMusic,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _exporting || _appendingMedia
                      ? null
                      : () => unawaited(_onVoiceRecordPressed()),
                  style: _voicePhase == _VoiceRecordPhase.idle
                      ? null
                      : IconButton.styleFrom(
                          foregroundColor: AppTheme.accent,
                          side: const BorderSide(color: AppTheme.accent),
                        ),
                  icon: Icon(
                    _voicePhase == _VoiceRecordPhase.recording
                        ? Icons.mic
                        : Icons.mic_none,
                  ),
                  tooltip: l10n.recordVoice,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildVoiceRecordOverlay(AppLocalizations l10n) {
    switch (_voicePhase) {
      case _VoiceRecordPhase.idle:
        return null;
      case _VoiceRecordPhase.countdown:
        return Positioned.fill(
          child: ColoredBox(
            color: const Color(0x66000000),
            child: Center(
              child: Text(
                '$_voiceCountdown',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 96,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
        );
      case _VoiceRecordPhase.armed:
      case _VoiceRecordPhase.recording:
        final recording = _voicePhase == _VoiceRecordPhase.recording;
        return Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: Material(
              color: recording ? const Color(0xFFE53935) : AppTheme.accent,
              borderRadius: BorderRadius.circular(28),
              elevation: 4,
              shadowColor: Colors.black54,
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: _voiceBusy
                    ? null
                    : () => unawaited(_onVoicePrimaryPressed()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        recording
                            ? Icons.stop_rounded
                            : Icons.fiber_manual_record,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        recording
                            ? l10n.stopVoiceRecording
                            : l10n.startVoiceRecording,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    }
  }
}

enum _VoiceRecordPhase { idle, armed, countdown, recording }

enum _EditorCoachKind {
  none,
  firstRun,
  splitTransition,
  splitReorder,
  textChrome,
}

class _CanvasRatioButton extends StatelessWidget {
  const _CanvasRatioButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

enum _DockResizeHint { up, down, both }

/// CapCut-style capsule + chevron grip between preview and timeline dock.
class _DockResizeGrip extends StatelessWidget {
  const _DockResizeGrip({required this.lit, required this.hint});

  final bool lit;
  final _DockResizeHint hint;

  @override
  Widget build(BuildContext context) {
    final barAlpha = lit ? 0.92 : 0.55;
    final tipAlpha = lit ? 0.7 : 0.4;
    final bar = Colors.white.withValues(alpha: barAlpha);
    final tip = Colors.white.withValues(alpha: tipAlpha);

    Widget chevron(bool up) => CustomPaint(
      size: const Size(18, 6),
      painter: _MiniChevronPainter(color: tip, up: up),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint == _DockResizeHint.up || hint == _DockResizeHint.both) ...[
          chevron(true),
          const SizedBox(height: 3),
        ],
        AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          width: lit ? 46 : 40,
          height: 5,
          decoration: BoxDecoration(
            color: bar,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: lit ? 0.35 : 0.18),
                blurRadius: lit ? 6 : 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
        if (hint == _DockResizeHint.down || hint == _DockResizeHint.both) ...[
          const SizedBox(height: 3),
          chevron(false),
        ],
      ],
    );
  }
}

class _MiniChevronPainter extends CustomPainter {
  _MiniChevronPainter({required this.color, required this.up});

  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final midY = up ? size.height * 0.7 : size.height * 0.3;
    final tipY = up ? size.height * 0.15 : size.height * 0.85;
    final path = Path()
      ..moveTo(2, midY)
      ..lineTo(size.width / 2, tipY)
      ..lineTo(size.width - 2, midY);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MiniChevronPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.up != up;
  }
}

/// Bottom-bar text affordance: plain **T+**, or template **T+** with ✨.
class _TextAddIcon extends StatelessWidget {
  const _TextAddIcon({required this.enabled, this.sparkle = false});

  final bool enabled;
  final bool sparkle;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppTheme.ink : AppTheme.ink.withValues(alpha: 0.38);
    final accent = enabled
        ? AppTheme.accentCyan
        : AppTheme.accentCyan.withValues(alpha: 0.4);

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

/// Owns its [TextEditingController] so the field stays valid through the
/// dialog's closing animation; disposing it right after `showDialog`
/// returned crashed the fading TextField (red error screen on back).
class _ProjectNameDialog extends StatefulWidget {
  const _ProjectNameDialog({required this.initial});

  final String initial;

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    Navigator.pop(context, value.isEmpty ? widget.initial : value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.projectNameTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        maxLines: null,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration(hintText: l10n.projectNameHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.save)),
      ],
    );
  }
}

/// Rising fill gauge + percent over the video preview while export runs.
class _ExportPreviewPercent extends StatelessWidget {
  const _ExportPreviewPercent({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final percent = (p * 100).round();
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: p <= 0 ? 0.02 : p,
            alignment: Alignment.bottomCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.accent.withValues(alpha: 0.2),
                    AppTheme.accent.withValues(alpha: 0.62),
                  ],
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Text(
            '$percent%',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 48,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
              color: Colors.white,
              shadows: const [Shadow(blurRadius: 18, color: Colors.black54)],
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen wait spinner while premium gate refreshes (no label).
class _ExportGateBusyOverlay extends StatelessWidget {
  const _ExportGateBusyOverlay();

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.35),
        child: const Center(
          child: SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AppTheme.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Dimmed timeline dock with scissors mascot + exporting label only.
class _ExportDockBusyOverlay extends StatefulWidget {
  const _ExportDockBusyOverlay({required this.label, required this.progress});

  final String label;
  final double progress;

  @override
  State<_ExportDockBusyOverlay> createState() => _ExportDockBusyOverlayState();
}

class _ExportDockBusyOverlayState extends State<_ExportDockBusyOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxH = constraints.maxHeight;
            final maxW = constraints.maxWidth;
            // Fullscreen collapse can leave a few pixels of dock height —
            // keep the dimmer, skip the mascot until there is room.
            if (!maxH.isFinite || maxH < 24) {
              return const SizedBox.expand();
            }

            // Compact dock (video maximized) — shrink mascot / drop label.
            final showLabel = maxH >= 110;
            final bounceAmp = showLabel ? 7.0 : (maxH >= 48 ? 3.0 : 0.0);
            final gap = showLabel ? 10.0 : 0.0;
            final labelH = showLabel ? 24.0 : 0.0;
            final budget =
                (maxH - gap - labelH - bounceAmp * 2).clamp(16.0, maxH);
            final mascot = showLabel
                ? (maxH * 0.48).clamp(36.0, math.min(78.0, budget)).toDouble()
                : (maxH * 0.55).clamp(16.0, math.min(56.0, budget)).toDouble();

            return Center(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: maxW < 200 ? 12 : 28,
                  vertical: 4,
                ),
                // Scale the intrinsic content down — never constrain the
                // Column to a tiny maxHeight (that overflows before scale).
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: _motion,
                        builder: (context, _) {
                          final t = _motion.value;
                          final bounce =
                              math.sin(t * math.pi * 2) * bounceAmp;
                          final wobble = math.sin(t * math.pi * 4) * 0.18;
                          return Transform.translate(
                            offset: Offset(0, bounce),
                            child: Transform.rotate(
                              angle: wobble,
                              child: CustomPaint(
                                size: Size(mascot, mascot),
                                painter: _ScissorsMascotPainter(phase: t),
                              ),
                            ),
                          );
                        },
                      ),
                      if (showLabel) ...[
                        SizedBox(height: gap),
                        Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.dmSans(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.ink,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Little scissors character snipping while the export runs.
class _ScissorsMascotPainter extends CustomPainter {
  _ScissorsMascotPainter({required this.phase});

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 4;
    final open = 0.35 + math.sin(phase * math.pi * 2) * 0.22;

    final blade = Paint()
      ..shader = AppTheme.brandGradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      );
    final grip = Paint()..color = const Color(0xFFFF8A3D);
    final rivet = Paint()..color = Colors.white;
    final spark = Paint()..color = Colors.white.withValues(alpha: 0.9);

    void bladePath(double angle, {required bool mirror}) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(angle);
      final path = Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(18, mirror ? -10 : 10, 34, mirror ? -4 : 4)
        ..quadraticBezierTo(22, mirror ? -2 : 2, 8, 0)
        ..close();
      canvas.drawPath(path, blade);
      canvas.drawCircle(Offset(-10, mirror ? -8 : 8), 7, grip);
      canvas.drawCircle(
        Offset(-10, mirror ? -8 : 8),
        3.2,
        Paint()..color = const Color(0xFF0B0610),
      );
      canvas.restore();
    }

    bladePath(-open, mirror: false);
    bladePath(open, mirror: true);
    canvas.drawCircle(Offset(cx, cy), 4.5, rivet);

    // Tiny sparkles near the tips.
    final sparkY = cy - 22 - math.sin(phase * math.pi * 2) * 4;
    canvas.drawCircle(Offset(cx + 26, sparkY), 2.2, spark);
    canvas.drawCircle(Offset(cx - 22, sparkY + 8), 1.6, spark);
  }

  @override
  bool shouldRepaint(covariant _ScissorsMascotPainter oldDelegate) {
    return oldDelegate.phase != phase;
  }
}
