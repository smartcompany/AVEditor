import 'dart:async';
import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
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
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/widgets/export_progress_dialog.dart';
import 'package:aveditor/widgets/text_studio_panel.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:aveditor/widgets/transition_picker_sheet.dart';
import 'package:aveditor/widgets/transition_preview_compositor.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:audioplayers/audioplayers.dart';
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
    with SingleTickerProviderStateMixin {
  /// Fallback extent before the chrome has been laid out once.
  static const _chromeExtentFallback = 260.0;

  /// Drag speed past which the chrome finishes in the flung direction.
  static const _chromeFlingVelocity = 320.0;

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

  Key get _primarySlotKey => _slotsSwapped ? _slotAuxKey : _slotMainKey;
  Key get _secondarySlotKey => _slotsSwapped ? _slotMainKey : _slotAuxKey;

  /// Aux opacity while a fade is active; null when not fading.
  double? _fadeProgress;

  /// Last fade window driven this playthrough (for handoff past [outgoing.end]).
  PreviewFadeWindow? _activeFade;

  /// Cut index whose aux stream is already anchored (avoid per-tick reseek).
  int? _fadeAnchoredAfterIndex;

  /// True while [_completeFadeHandoff] is awaiting the main seek settle.
  var _fadeHandoffInFlight = false;

  /// Serializes aux seeks so overlapping fade ticks don't race.
  int _fadeSyncGen = 0;

  /// Pause once the main playhead reaches this time (transition-length preview).
  Duration? _transitionPreviewUntil;

  /// Bumped to cancel an in-flight [_previewTransitionAtCut] (e.g. panel close).
  int _transitionPreviewGen = 0;

  /// True while the transition picker sheet is up — hide the timeline chrome
  /// grab so it does not sit next to the sheet's own handle.
  var _transitionPickerOpen = false;

  VideoProject? _project;
  String? _selectedOverlayId;
  String? _selectedSegmentId;
  String? _selectedMusicId;
  int? _selectedTransitionAfterIndex;

  /// Overlay currently edited inline on the preview (keyboard open).
  String? _editingOverlayId;

  /// CapCut-style text studio is open for this overlay id.
  String? _textStudioOverlayId;
  bool _ready = false;
  bool _exporting = false;
  bool _applyingHistory = false;
  String? _errorMessage;

  /// Optimistic playhead while `seekTo` is in flight (avoids timeline jitter).
  Duration? _scrubPlayhead;

  final _export = ExportService();
  final _exportSave = ExportSaveService();
  final _settings = const AppSettingsService();
  final _projectStorage = const ProjectStorageService();
  final _history = EditorHistory();
  final _thumbnailService = const TimelineThumbnailService();
  final _probe = const VideoProbeService();
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();
  final _timelineKey = GlobalKey<TimelineWidgetState>();
  final _musicPlayer = AudioPlayer();

  /// Last music clip loaded into [_musicPlayer]; null when stopped.
  String? _syncedMusicId;
  int _musicSyncGen = 0;

  List<TimelineFilmstripFrame> _filmstripFrames = [];
  final Map<String, List<double>> _musicWaveforms = {};
  List<double> _sourceAudioWaveform = const [];
  bool _hasSourceAudio = false;

  Timer? _saveDebounce;

  /// Measures the chrome at full height so drags map 1:1 to finger travel.
  final _chromeContentKey = GlobalKey();

  /// 1 = timeline and actions shown, 0 = collapsed to just the video.
  late final AnimationController _chrome;

  /// Text-field focus inside the studio (compose = input+tabs above keyboard).
  var _textStudioFieldFocused = false;

  /// Override for the text-studio sheet height. `null` = entry (2/3) height.
  double? _textStudioHeightOverride;

  /// Sheet [Positioned.bottom] while composing (keyboard inset).
  var _textStudioSheetBottom = 0.0;

  static const _chromeHandleHeight = 26.0;

  Duration get _playhead {
    return _scrubPlayhead ?? _controller?.value.position ?? Duration.zero;
  }

  /// Timeline playhead during a dual-layer transition.
  ///
  /// Packed timeline time does not overlap clips, but preview plays outgoing
  /// tail and incoming head in the same wall-clock window. Mapping the live
  /// decoder position alone therefore crawls to the cut, then jumps ~[td]
  /// into the next clip at handoff. Remap with [t] so the playhead advances
  /// continuously across both halves and lands where the swapped controller is.
  Duration get _timelinePlayhead {
    final project = _project;
    final fade = _activeFade;
    if (project == null || fade == null || fade.td <= Duration.zero) {
      return _playhead;
    }
    final cut = cutExportTimeAfter(project.segments, fade.afterIndex);
    final t = _fadeHandoffInFlight ? 1.0 : fade.t;
    final traveledMs =
        (t * 2 * fade.td.inMilliseconds).round().clamp(0, 1 << 30);
    final sequenceTime = cut - fade.td + Duration(milliseconds: traveledMs);
    return exportTimeToSourceTime(project.segments, sequenceTime);
  }

  @override
  void initState() {
    super.initState();
    _chrome = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 220),
    );
    _initVideo();
  }

  double get _chromeExtent {
    final box = _chromeContentKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.size.height > 0) {
      return box.size.height;
    }
    return _chromeExtentFallback;
  }

  void _onChromeDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta;
    if (delta == null) return;
    _chrome.value = (_chrome.value - delta / _chromeExtent).clamp(0.0, 1.0);
  }

  void _onChromeDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final expand = velocity.abs() > _chromeFlingVelocity
        ? velocity < 0
        : _chrome.value >= 0.5;
    _settleChrome(expand: expand);
  }

  void _settleChrome({required bool expand}) {
    _chrome.animateTo(
      expand ? 1.0 : 0.0,
      curve: expand ? Curves.easeOutCubic : Curves.easeInCubic,
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
              overlays: stored.overlays,
              preset: stored.preset,
              rotation: stored.rotation,
              updatedAt: stored.updatedAt,
            )
          : stored;

      project.segments
        ..clear()
        ..addAll(normalizeSegments(project.segments, sourceDuration: duration));
      if (project.segments.isEmpty ||
          totalKeptDuration(project.segments) <= Duration.zero) {
        project.segments
          ..clear()
          ..addAll(segmentsFromTrim(start: Duration.zero, end: duration));
      }

      setState(() {
        _slotMain = controller;
        _slotsSwapped = false;
        _project = project;
        _ready = true;
        _errorMessage = null;
      });

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
    if (_fadeHandoffInFlight) return;

    final pos = controller.value.position;

    final fade = previewFadeAt(project.segments, pos);
    if (fade != null) {
      final entering = _fadeAnchoredAfterIndex != fade.afterIndex;
      _activeFade = fade;
      if (entering || _auxController == null) {
        // Only the first entry into a cut does async seek/play setup.
        unawaited(_driveFadePreview(fade));
      } else {
        // Already anchored — update blend progress without reseeking.
        if (_fadeProgress != fade.t) {
          setState(() => _fadeProgress = fade.t);
        }
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

    if (_activeFade != null) {
      final active = _activeFade!;
      // Past the outgoing end → hand off to the incoming side once.
      if (pos >= active.outgoing.end) {
        if (!_fadeHandoffInFlight) {
          unawaited(_completeFadeHandoff(active));
        }
        return;
      }
      // Still inside the fade span but previewFadeAt missed a frame — keep going.
      final windowStart = active.outgoing.end - active.td;
      if (pos >= windowStart && pos < active.outgoing.end) {
        final span = active.td.inMilliseconds;
        final t = span <= 0
            ? 1.0
            : ((pos.inMilliseconds - windowStart.inMilliseconds) / span)
                .clamp(0.0, 1.0);
        final continued = PreviewFadeWindow(
          afterIndex: active.afterIndex,
          t: t,
          outgoing: active.outgoing,
          incoming: active.incoming,
          td: active.td,
        );
        _activeFade = continued;
        if (_fadeProgress != t) {
          setState(() => _fadeProgress = t);
        }
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
      // Pause aux, seek to the incoming start, then play with main.
      try {
        await aux.pause();
      } catch (_) {}
      if (!mounted || gen != _fadeSyncGen) return;
      await aux.seekTo(fade.incoming.start);
      if (!mounted || gen != _fadeSyncGen) return;
      // Wait briefly so the first incoming frame is decoded before blending.
      final deadline = DateTime.now().add(const Duration(milliseconds: 200));
      while (DateTime.now().isBefore(deadline)) {
        if (!mounted || gen != _fadeSyncGen) return;
        final drift =
            (aux.value.position - fade.incoming.start).inMilliseconds.abs();
        if (drift <= 50 && !aux.value.isBuffering) break;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!mounted || gen != _fadeSyncGen) return;
      if (main.value.isPlaying) {
        await aux.play();
      }
    } else if (main.value.isPlaying) {
      if (!aux.value.isPlaying) await aux.play();
    } else if (aux.value.isPlaying) {
      await aux.pause();
    }
    if (!mounted || gen != _fadeSyncGen) return;

    if (_fadeProgress != fade.t) {
      setState(() => _fadeProgress = fade.t);
    }
  }

  /// Finish a dual-layer preview without seeking the visible stream.
  ///
  /// Seeking the main player to match aux lands on keyframes and causes the
  /// visible "frame jump". Instead we promote the already-correct aux player
  /// to be the primary controller.
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
        _fadeProgress = null;
        _fadeAnchoredAfterIndex = null;
        if (mounted) setState(() {});
        return;
      }

      final wasPlaying = main.value.isPlaying || aux.value.isPlaying;

      // Hold the last blend frame on incoming only, then swap controllers so
      // the already-decoded incoming stream continues without a seek hitch.
      if (mounted) {
        setState(() => _fadeProgress = 1.0);
      }
      try {
        await main.pause();
      } catch (_) {}
      if (!mounted || gen != _fadeSyncGen) return;

      // One frame so the compositor can paint full-incoming before the swap.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!mounted || gen != _fadeSyncGen) return;

      main.removeListener(_onVideoTick);
      // Flip which physical slot is the live timeline player — no seek.
      _slotsSwapped = !_slotsSwapped;
      _controller!.addListener(_onVideoTick);

      _activeFade = null;
      _fadeProgress = null;
      _fadeAnchoredAfterIndex = null;

      try {
        await _auxController?.setVolume(0);
        await _auxController?.pause();
      } catch (_) {}

      if (wasPlaying) {
        if (!_controller!.value.isPlaying) {
          await _controller!.play();
        }
      } else if (_controller!.value.isPlaying) {
        await _controller!.pause();
      }

      if (mounted) setState(() {});
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
    _fadeProgress = null;
    _fadeAnchoredAfterIndex = null;
    final aux = _auxController;
    if (aux != null && aux.value.isInitialized) {
      try {
        await aux.pause();
        await aux.setVolume(0);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Widget _buildPreviewVideoChild(VideoPlayerController main) {
    final progress = _fadeProgress;
    final aux = _auxController;
    final active = _activeFade;
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

    if (progress == null || active == null || aux == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(_controller!, key: _primarySlotKey),
          Offstage(
            offstage: true,
            child: VideoPlayer(_auxController!, key: _secondarySlotKey),
          ),
        ],
      );
    }

    final plan = TransitionEngine.instance.plan(active.outgoing.transition);
    return TransitionPreviewCompositor(
      key: const ValueKey('preview_transition'),
      outgoing: main,
      incoming: aux,
      outgoingPlayerKey: _primarySlotKey,
      incomingPlayerKey: _secondarySlotKey,
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
    if (!_hasSourceAudio) {
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

    final pos = controller.value.position;
    final scrub = _scrubPlayhead;
    if (scrub != null) {
      // Drop optimistic scrub once the decoder catches up.
      if ((pos.inMilliseconds - scrub.inMilliseconds).abs() <= 100) {
        _scrubPlayhead = null;
      } else if (!controller.value.isPlaying) {
        // Still seeking — keep showing scrub time, refresh other UI lightly.
        setState(() {});
        return;
      } else {
        _scrubPlayhead = null;
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
    _saveDebounce?.cancel();
    final project = _project;
    if (project != null) {
      unawaited(_projectStorage.save(project));
    }
    _disposeFilmstrip();
    _slotMain?.removeListener(_onVideoTick);
    _slotAux?.removeListener(_onVideoTick);
    final main = _slotMain;
    final aux = _slotAux;
    _slotMain = null;
    _slotAux = null;
    unawaited(main?.dispose() ?? Future<void>.value());
    unawaited(aux?.dispose() ?? Future<void>.value());
    unawaited(_musicPlayer.dispose());
    _chrome.dispose();
    super.dispose();
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

  bool get _inTextStudio => _textStudioOverlayId != null;

  /// Bottom sheets that already have a drag pill — hide the chrome handle.
  bool get _hideChromeHandle => _inTextStudio || _transitionPickerOpen;

  void _seek(Duration position) {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    // The timeline scrolls to keep the playhead centred, so restricting the
    // playhead to the trim range would also make the rest of the clip — and
    // its trim handles — unreachable. Playback still stops at the trim end.
    final clamped = clampDuration(position, Duration.zero, project.duration);
    _scrubPlayhead = clamped;
    unawaited(_tearDownFadePreview());
    controller.seekTo(clamped);
    unawaited(_syncMusicPlayback());
    _syncVideoAudioVolume();
    setState(() {});
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
    if (controller.value.isPlaying) {
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

    if (!controller.value.isPlaying) return;
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
    if (_inTextStudio) {
      // Keep the text panel; only dismiss the keyboard / field focus.
      FocusManager.instance.primaryFocus?.unfocus();
      if (_textStudioFieldFocused) {
        setState(() => _textStudioFieldFocused = false);
      }
      return;
    }
    if (_editingOverlayId != null) {
      _finishInlineEditing('preview_outside');
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
    final index = cutIndex ??
        _selectedTransitionAfterIndex ??
        nearestCutIndex(project.segments, sequenceTime);
    if (index < 0 || index >= project.segments.length - 1) {
      return;
    }

    final current = project.segments[index];
    final next = project.segments[index + 1];
    final maxTd = () {
      final maxMs = [
        current.duration.inMilliseconds,
        next.duration.inMilliseconds,
      ].reduce((a, b) => a < b ? a : b);
      final limit = maxMs > 100 ? maxMs - 50 : maxMs;
      return Duration(milliseconds: limit.clamp(50, 1 << 30));
    }();
    const minTd = Duration(milliseconds: 50);

    setState(() {
      _selectedTransitionAfterIndex = index;
      _selectedSegmentId = null;
      _selectedOverlayId = null;
      _selectedMusicId = null;
      _transitionPickerOpen = true;
    });

    await showTransitionPickerSheet(
      context,
      initialSelectedId: current.transitionId ?? 'none',
      initialDuration: current.hasTransition
          ? clampedTransitionDuration(current, next: next)
          : const Duration(milliseconds: 500),
      minDuration: minTd,
      maxDuration: maxTd < minTd ? minTd : maxTd,
      initialParameters: current.transition?.parameters ?? const {},
      onApplied: (applied) {
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
                duration: clamped <= Duration.zero
                    ? applied.duration
                    : clamped,
              ),
            );
          }
        });
        setState(() {
          _selectedTransitionAfterIndex = applied.isNone ? null : index;
        });
        if (applied.isNone) {
          _transitionPreviewUntil = null;
          unawaited(_tearDownFadePreview());
          unawaited(_controller?.pause() ?? Future<void>.value());
          return;
        }
        // Re-tap / apply: play exactly the transition window on the main timeline.
        unawaited(_previewTransitionAtCut(index));
      },
      onDurationChanged: (duration) {
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
        // Rebuild timeline so the transition chip width tracks the slider.
        // Avoid _mutate here — slider ticks must not flood undo history.
        setState(() {});
        _scheduleSave();
      },
      onParametersChanged: (parameters) {
        if (!mounted) return;
        final project = _project;
        if (project == null || index >= project.segments.length - 1) return;
        final segment = project.segments[index];
        if (!segment.hasTransition) return;
        project.segments[index] = segment.copyWith(
          transition: segment.transition!.copyWith(parameters: parameters),
        );
        _scheduleSave();
      },
    );
    if (!mounted) return;
    // Cancel any in-flight preview before pausing — otherwise a late play()
    // from [_previewTransitionAtCut] / fade handoff can resume after this close.
    _transitionPreviewGen++;
    _transitionPreviewUntil = null;
    _transitionPickerOpen = false;
    await _tearDownFadePreview();
    await _controller?.pause();
    await _auxController?.pause();
    unawaited(_syncMusicPlayback());
    if (mounted) setState(() {});
  }

  /// Seek to the cut and play only for the transition duration on the main timeline.
  Future<void> _previewTransitionAtCut(int cutIndex) async {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;
    if (cutIndex < 0 || cutIndex >= project.segments.length - 1) return;

    final gen = ++_transitionPreviewGen;
    final outgoing = project.segments[cutIndex];
    final incoming = project.segments[cutIndex + 1];
    final td = clampedTransitionDuration(outgoing, next: incoming);
    final previewStart = td > Duration.zero
        ? outgoing.end - td
        : outgoing.end - const Duration(milliseconds: 400);
    final clampedStart = previewStart < outgoing.start
        ? outgoing.start
        : previewStart;

    _scrubPlayhead = clampedStart;
    _transitionPreviewUntil =
        td > Duration.zero ? clampedStart + td : null;

    await _tearDownFadePreview();
    if (!mounted || gen != _transitionPreviewGen) return;

    if (outgoing.hasTransition && td > Duration.zero) {
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
    if (td <= Duration.zero) {
      await controller.pause();
      _transitionPreviewUntil = null;
    } else {
      await controller.play();
    }
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

  void _addTextOverlay() {
    final project = _project;
    final controller = _controller;
    if (project == null || controller == null) return;

    if (controller.value.isPlaying) {
      controller.pause();
    }

    final start = _playhead;
    var end = start + const Duration(seconds: 3);
    if (end - start < minOverlayDuration) {
      end = start + minOverlayDuration;
    }

    final overlay = fitOverlayBoxToText(
      TextOverlay(text: '', start: start, end: end),
    );
    _chrome.value = 1;
    _textStudioFieldFocused = false;
    _textStudioHeightOverride = null;
    _textStudioSheetBottom = 0;
    _mutate((p) {
      final placed = assignOverlayLane(
        p.overlays,
        overlay,
        preferLowestLane: true,
      );
      p.overlays.add(placed);
      final compacted = compactOverlayLanes(p.overlays);
      p.overlays
        ..clear()
        ..addAll(compacted);
      _selectedOverlayId = placed.id;
      _selectedSegmentId = null;
      _selectedMusicId = null;
      _selectedTransitionAfterIndex = null;
      _editingOverlayId = null;
      _textStudioOverlayId = placed.id;
    });
  }

  void _openTextStudio(TextOverlay overlay) {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      controller.pause();
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _chrome.value = 1;
    setState(() {
      _textStudioFieldFocused = false;
      _textStudioHeightOverride = null;
      _textStudioSheetBottom = 0;
      _selectedOverlayId = overlay.id;
      _selectedSegmentId = null;
      _selectedMusicId = null;
      _selectedTransitionAfterIndex = null;
      _editingOverlayId = null;
      _textStudioOverlayId = overlay.id;
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
      _deleteOverlay(id);
      setState(() {
        _textStudioOverlayId = null;
        _textStudioFieldFocused = false;
        _textStudioHeightOverride = null;
        _textStudioSheetBottom = 0;
      });
      return;
    }

    if (overlay != null && overlay.text != overlay.text.trim()) {
      _updateOverlay(overlay.copyWith(text: overlay.text.trim()));
    }

    setState(() {
      _textStudioOverlayId = null;
      _textStudioFieldFocused = false;
      _textStudioHeightOverride = null;
      _textStudioSheetBottom = 0;
      _selectedOverlayId = source == 'preview_outside' ? null : id;
    });
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

    if (overlay != null && overlay.text.trim().isEmpty) {
      OverlayEventLog.log('Editor', 'finishInlineEditingDeleteEmpty', {
        'source': source,
        'id': id,
      });
      _deleteOverlay(id);
      return;
    }

    if (overlay != null && overlay.text != overlay.text.trim()) {
      _updateOverlay(overlay.copyWith(text: overlay.text.trim()));
    }

    setState(() {
      _editingOverlayId = null;
      // Tap outside the box dismisses chrome entirely; other exits keep selection.
      _selectedOverlayId = source == 'preview_outside' ? null : id;
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
      // Body tap → on-canvas edit only. Studio opens from add / corner edit.
      _textStudioOverlayId = null;
      _textStudioFieldFocused = false;
      _textStudioHeightOverride = null;
      _textStudioSheetBottom = 0;
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
        _textStudioFieldFocused = false;
        _textStudioHeightOverride = null;
        _textStudioSheetBottom = 0;
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
          // Open at max (2/3 screen); user can snap down to entry via the handle.
          final sheetH =
              (_textStudioHeightOverride ?? maxH).clamp(0.0, bodyH);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Preview + timeline stay laid out exactly as usual — the text
              // sheet only paints on top and never reflows this column.
              Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final targetWidth = constraints.maxWidth;
                          final targetHeight = targetWidth * 16 / 9;
                          return Listener(
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
                              _previewKey.currentState?.handlePointerDown(e);
                            },
                            onPointerMove: (e) =>
                                _previewKey.currentState?.handlePointerMove(e),
                            onPointerUp: (e) => _previewKey.currentState
                                ?.handlePointerUp(e.pointer),
                            onPointerCancel: (e) => _previewKey.currentState
                                ?.handlePointerCancel(e.pointer),
                            child: SizedBox.expand(
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
                                    videoChild: _buildPreviewVideoChild(controller),
                                    overlays: project.overlays,
                                    segments: project.segments,
                                    position: _playhead,
                                    clipRotation: project.rotation,
                                    hostViewportSize: Size(
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                    selectedOverlayId: _selectedOverlayId,
                                    editingOverlayId: _editingOverlayId,
                                    textHint: l10n.textOverlayHint,
                                    onOverlaySelected: (overlay) {
                                      if (_inTextStudio &&
                                          _textStudioOverlayId != overlay.id) {
                                        _closeTextStudio(
                                          'select_other_overlay',
                                        );
                                      }
                                      if (_editingOverlayId != null &&
                                          _editingOverlayId != overlay.id) {
                                        _finishInlineEditing(
                                          'select_other_overlay',
                                        );
                                      }
                                      setState(
                                        () => _selectedOverlayId = overlay.id,
                                      );
                                    },
                                    onRequestEdit: _startInlineEditing,
                                    onBackgroundTap: _onPreviewBackgroundTap,
                                    onOverlayTextChanged: _onOverlayTextChanged,
                                    onEditingComplete: _finishInlineEditing,
                                    onOverlayOffsetChanged: (overlay, offset) {
                                      _patchOverlay(
                                        overlay.id,
                                        (current) =>
                                            current.copyWith(offset: offset),
                                      );
                                    },
                                    onOverlayDeleted: _deleteOverlayByOverlay,
                                    onOverlayDuplicated: _duplicateOverlay,
                                    onOverlayEdit: (overlay) {
                                      setState(
                                        () => _selectedOverlayId = overlay.id,
                                      );
                                      _editSelectedOverlay();
                                    },
                                    onOverlayBoxChanged: (overlay, transform) {
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
                                          'offset': transform.offset,
                                          'rotation': transform.rotation
                                              .toStringAsFixed(3),
                                        },
                                      );
                                      _patchOverlay(
                                        overlay.id,
                                        (current) => current.copyWith(
                                          boxWidth: transform.width,
                                          boxHeight: transform.height,
                                          fontSize: transform.fontSize,
                                          offset: transform.offset,
                                          rotation: transform.rotation,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: inTextStudio,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Keep the slot so the preview does not jump when a
                        // bottom sheet hides the grab pill.
                        if (_hideChromeHandle)
                          const SizedBox(height: _chromeHandleHeight)
                        else
                          _buildChromeHandle(l10n),
                        _buildCollapsibleChrome(
                          l10n: l10n,
                          project: project,
                          controller: controller,
                          isInlineEditing: _editingOverlayId != null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (inTextStudio && studioOverlay != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _textStudioSheetBottom,
                  child: SizedBox(
                    width: double.infinity,
                    height: sheetH,
                    child: TextStudioPanel(
                      overlay: studioOverlay,
                      textHint: l10n.textOverlayHint,
                      maxSheetHeight: bodyH,
                      onChanged: _updateOverlay,
                      onTextChanged: (text) {
                        final current = _textStudioOverlay;
                        if (current == null) return;
                        _updateOverlay(current.copyWith(text: text));
                      },
                      onConfirm: () => _closeTextStudio('studio_confirm'),
                      onFieldFocusChanged: (focused) {
                        if (_textStudioFieldFocused == focused) return;
                        setState(() => _textStudioFieldFocused = focused);
                      },
                      onHeightChanged: (height, {double bottom = 0}) {
                        if (height == null) {
                          if (_textStudioHeightOverride == null &&
                              _textStudioSheetBottom == 0) {
                            return;
                          }
                          setState(() {
                            _textStudioHeightOverride = null;
                            _textStudioSheetBottom = 0;
                          });
                          return;
                        }
                        final clamped = height.clamp(0.0, bodyH);
                        if (_textStudioHeightOverride == clamped &&
                            _textStudioSheetBottom == bottom) {
                          return;
                        }
                        setState(() {
                          _textStudioHeightOverride = clamped;
                          _textStudioSheetBottom = bottom;
                        });
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Always-visible grab bar — the only way back once the chrome is collapsed.
  Widget _buildChromeHandle(AppLocalizations l10n) {
    // Collapsed, the handle is the bottom-most widget, so it has to clear the
    // home indicator itself; expanded, the action bar's padding already does.
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    return AnimatedBuilder(
      animation: _chrome,
      builder: (context, _) {
        final expanded = _chrome.value > 0.5;
        return Semantics(
          button: true,
          label: expanded ? l10n.hideTimeline : l10n.showTimeline,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _onChromeDragUpdate,
            onVerticalDragEnd: _onChromeDragEnd,
            onTap: () => _settleChrome(expand: !expanded),
            child: Padding(
              padding: EdgeInsets.only(
                bottom: safeBottom * (1 - _chrome.value),
              ),
              child: SizedBox(
                height: _chromeHandleHeight,
                child: Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
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
  }) {
    Widget timeline = _buildTimeline(project: project, controller: controller);
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

    final content = Column(
      key: _chromeContentKey,
      mainAxisSize: MainAxisSize.min,
      children: [timeline, const SizedBox(height: 8), actions],
    );

    return AnimatedBuilder(
      animation: _chrome,
      builder: (context, child) {
        // Shrinking the slot pushes the chrome off the bottom edge while the
        // preview above claims the freed height.
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _chrome.value,
            child: child,
          ),
        );
      },
      child: content,
    );
  }

  Widget _buildTimeline({
    required VideoProject project,
    required VideoPlayerController controller,
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
      isPlaying: controller.value.isPlaying,
      onTogglePlay: _togglePlay,
      onHandleDragUpdate: _onChromeDragUpdate,
      onHandleDragEnd: _onChromeDragEnd,
      selectedOverlayId: _selectedOverlayId,
      selectedSegmentId: _selectedSegmentId,
      selectedMusicId: _selectedMusicId,
      selectedTransitionAfterIndex: _selectedTransitionAfterIndex,
      onPlayheadChanged: _seek,
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  onPressed: _exporting ? null : _addTextOverlay,
                  icon: const Icon(Icons.text_increase),
                  tooltip: l10n.addText,
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _selectedOverlay == null || _exporting
                      ? null
                      : _editSelectedOverlay,
                  icon: const Icon(Icons.edit_note_outlined),
                  tooltip: l10n.editText,
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
