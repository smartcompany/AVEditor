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
import 'package:aveditor/services/music_storage_service.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/timeline_thumbnail_service.dart';
import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/widgets/export_progress_dialog.dart';
import 'package:aveditor/widgets/text_overlay_editor_sheet.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
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

  VideoPlayerController? _controller;
  VideoProject? _project;
  String? _selectedOverlayId;
  String? _selectedSegmentId;

  /// Overlay currently edited inline on the preview (keyboard open).
  String? _editingOverlayId;
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
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();
  final _musicPlayer = AudioPlayer();

  List<TimelineFilmstripFrame> _filmstripFrames = [];

  Timer? _saveDebounce;

  /// Measures the chrome at full height so drags map 1:1 to finger travel.
  final _chromeContentKey = GlobalKey();

  /// 1 = timeline and actions shown, 0 = collapsed to just the video.
  late final AnimationController _chrome;

  Duration get _playhead {
    return _scrubPlayhead ?? _controller?.value.position ?? Duration.zero;
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
        ..addAll(
          normalizeSegments(
            project.segments,
            sourceDuration: duration,
          ),
        );
      if (project.segments.isEmpty ||
          totalKeptDuration(project.segments) <= Duration.zero) {
        project.segments
          ..clear()
          ..addAll(segmentsFromTrim(start: Duration.zero, end: duration));
      }

      setState(() {
        _controller = controller;
        _project = project;
        _ready = true;
        _errorMessage = null;
      });

      unawaited(_loadFilmstrip(project.sourcePath, project.duration));

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

  Duration _sequenceTimeForSplit(List<ClipSegment> segments, Duration rawPlayhead) {
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
    _applyingHistory = false;
    setState(() {});
    _scheduleSave();
    unawaited(_syncMusicPlayback());
  }

  void _splitAtPlayhead() {
    final project = _project;
    if (project == null || _exporting) return;
    if (project.duration <= Duration.zero) return;

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _advancePlaybackPastGaps() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null || !controller.value.isPlaying) {
      return;
    }

    final pos = controller.value.position;
    if (isInKeptRegion(project.segments, pos)) {
      final segment = segmentAt(project.segments, pos);
      if (segment != null && pos >= segment.end - const Duration(milliseconds: 80)) {
        final next = nextSegmentStartAfter(project.segments, pos);
        if (next != null) {
          controller.seekTo(next);
        } else {
          controller.pause();
          controller.seekTo(segment.end);
        }
      }
      return;
    }

    final next = nextSegmentStartAfter(project.segments, pos);
    if (next != null) {
      controller.seekTo(next);
    } else {
      final last = project.segments.last;
      controller.pause();
      controller.seekTo(last.end);
    }
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
    if (pos >= project.trim.end) {
      controller.pause();
      controller.seekTo(project.trim.end);
    }
    _advancePlaybackPastGaps();
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
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
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

  void _seek(Duration position) {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    // The timeline scrolls to keep the playhead centred, so restricting the
    // playhead to the trim range would also make the rest of the clip — and
    // its trim handles — unreachable. Playback still stops at the trim end.
    final clamped = clampDuration(position, Duration.zero, project.duration);
    _scrubPlayhead = clamped;
    controller.seekTo(clamped);
    unawaited(_syncMusicPlayback());
    setState(() {});
  }

  Future<void> _syncMusicPlayback() async {
    final project = _project;
    final controller = _controller;
    final music = project?.backgroundMusic;
    if (project == null || controller == null || music == null) {
      await _musicPlayer.stop();
      return;
    }

    final musicPath = MusicStorageService.musicPath(
      p.dirname(project.sourcePath),
      music,
    );
    if (!await File(musicPath).exists()) {
      await _musicPlayer.stop();
      return;
    }

    await _musicPlayer.setSource(DeviceFileSource(musicPath));
    await _musicPlayer.setVolume(music.volume);

    final playhead = _playhead;
    final musicPosition = music.sourceOffset + (playhead - music.timelineStart);
    if (musicPosition.isNegative) {
      await _musicPlayer.pause();
      return;
    }

    await _musicPlayer.seek(musicPosition);
    if (controller.value.isPlaying) {
      await _musicPlayer.resume();
    } else {
      await _musicPlayer.pause();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    final project = _project;
    if (controller == null || project == null) return;

    _scrubPlayhead = null;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      if (controller.value.position >= project.trim.end ||
          controller.value.position < project.trim.start ||
          !isInKeptRegion(project.segments, controller.value.position)) {
        final start = segmentAt(project.segments, controller.value.position)
                ?.start ??
            project.segments.first.start;
        controller.seekTo(start);
      }
      controller.play();
    }
    unawaited(_syncMusicPlayback());
    setState(() {});
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
          current: project.backgroundMusic,
        ),
      ),
    );
    if (picked == null) return;

    setState(() {
      project.backgroundMusic = picked.copyWith(
        timelineStart: project.trim.start,
      );
    });
    _history.record(_snapshot());
    _scheduleSave();
    await _syncMusicPlayback();
  }

  void _removeMusic() {
    final project = _project;
    if (project == null) return;
    _mutate((p) => p.backgroundMusic = null);
    unawaited(_musicPlayer.stop());
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
    if (end > project.duration) {
      end = project.duration;
    }
    if (end - start < minOverlayDuration) {
      end = start + minOverlayDuration;
      if (end > project.duration) {
        end = project.duration;
      }
    }

    final overlay = TextOverlay(text: '', start: start, end: end);
    _mutate((p) {
      p.overlays.add(overlay);
      _selectedOverlayId = overlay.id;
      _editingOverlayId = overlay.id;
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
      p.overlays.insert(
        index == -1 ? p.overlays.length : index + 1,
        copy,
      );
      _selectedOverlayId = copy.id;
      _editingOverlayId = null;
    });
  }

  void _updateOverlay(TextOverlay updated) {
    final project = _project;
    if (project == null) return;

    final index = project.overlays.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    setState(() {
      project.overlays[index] = updated;
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
      project.overlays[index] = patch(project.overlays[index]);
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
      _selectedOverlayId = id;
    });
    OverlayEventLog.log('Editor', 'finishInlineEditingDone', {
      'source': source,
      'selectedId': id,
      'textLen': overlay?.text.length ?? 0,
    });
  }

  void _startInlineEditing(TextOverlay overlay) {
    OverlayEventLog.log('Editor', 'startInlineEditing', {'id': overlay.id});
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      controller.pause();
    }
    setState(() {
      _selectedOverlayId = overlay.id;
      _editingOverlayId = overlay.id;
    });
  }

  void _deleteOverlay(String id) {
    final project = _project;
    if (project == null) return;

    _mutate((p) {
      p.overlays.removeWhere((o) => o.id == id);
      if (_selectedOverlayId == id) {
        _selectedOverlayId = null;
      }
      if (_editingOverlayId == id) {
        _editingOverlayId = null;
      }
    });
  }

  Future<void> _editSelectedOverlay() async {
    final overlay = _selectedOverlay;
    if (overlay == null) return;

    if (_editingOverlayId != null) {
      _finishInlineEditing('edit_sheet');
    }

    final current = _selectedOverlay;
    if (current == null) return;

    await showTextOverlayEditorSheet(
      context: context,
      overlay: current,
      onSave: _updateOverlay,
      onDelete: () => _deleteOverlay(current.id),
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
    final isInlineEditing = _editingOverlayId != null;

    return Scaffold(
      // Keyboard slides over the bottom controls; layout stays fixed so the preview
      // does not jump when editing starts.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(l10n.editorTitle),
        actions: [
          if (isInlineEditing)
            TextButton(
              onPressed: () => _finishInlineEditing('save_button'),
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
            if (_selectedOverlay != null)
              IconButton(
                onPressed: _editSelectedOverlay,
                icon: const Icon(Icons.edit_outlined),
                tooltip: l10n.editText,
              ),
            IconButton(
              onPressed: _openUpload,
              icon: const Icon(Icons.upload_outlined),
              tooltip: l10n.uploadShorts,
            ),
          ],
        ],
      ),
      body: Column(
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
                      OverlayEventLog.log('EditorShell', 'pointerDown', {
                        'global': e.position,
                        'hasPreviewState': _previewKey.currentState != null,
                      });
                      _previewKey.currentState?.handlePointerDown(e);
                    },
                    onPointerMove: (e) =>
                        _previewKey.currentState?.handlePointerMove(e),
                    onPointerUp: (e) =>
                        _previewKey.currentState?.handlePointerUp(e.pointer),
                    onPointerCancel: (e) => _previewKey.currentState
                        ?.handlePointerCancel(e.pointer),
                    // FittedBox shrink-wraps to the scaled canvas, which would
                    // leave the black gutter beside it outside the Listener.
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
                            videoChild: VideoPlayer(controller),
                            overlays: project.overlays,
                            segments: project.segments,
                            position: _playhead,
                            clipRotation: project.rotation,
                            selectedOverlayId: _selectedOverlayId,
                            editingOverlayId: _editingOverlayId,
                            textHint: l10n.textOverlayHint,
                            onOverlaySelected: (overlay) {
                              if (_editingOverlayId != null &&
                                  _editingOverlayId != overlay.id) {
                                _finishInlineEditing('select_other_overlay');
                              }
                              setState(() => _selectedOverlayId = overlay.id);
                            },
                            onRequestEdit: _startInlineEditing,
                            onBackgroundTap: _togglePlay,
                            onOverlayTextChanged: _onOverlayTextChanged,
                            onEditingComplete: _finishInlineEditing,
                            onOverlayOffsetChanged: (overlay, offset) {
                              _patchOverlay(
                                overlay.id,
                                (current) => current.copyWith(offset: offset),
                              );
                            },
                            onOverlayDeleted: (overlay) =>
                                _deleteOverlay(overlay.id),
                            onOverlayDuplicated: _duplicateOverlay,
                            onOverlayBoxChanged: (overlay, transform) {
                              OverlayEventLog.log(
                                'Editor',
                                'overlayBoxChanged',
                                {
                                  'id': overlay.id,
                                  'width': transform.width.toStringAsFixed(1),
                                  'height': transform.height.toStringAsFixed(1),
                                  'font': transform.fontSize.toStringAsFixed(1),
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
          _buildChromeHandle(l10n),
          _buildCollapsibleChrome(
            l10n: l10n,
            project: project,
            controller: controller,
            isInlineEditing: isInlineEditing,
          ),
        ],
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
                height: 26,
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
      duration: project.duration,
      trimStart: project.trim.start,
      trimEnd: project.trim.end,
      segments: project.segments,
      overlays: project.overlays,
      filmstripFrames: _filmstripFrames,
      playhead: _playhead,
      isPlaying: controller.value.isPlaying,
      onTogglePlay: _togglePlay,
      onHandleDragUpdate: _onChromeDragUpdate,
      onHandleDragEnd: _onChromeDragEnd,
      selectedOverlayId: _selectedOverlayId,
      selectedSegmentId: _selectedSegmentId,
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
        });
      },
      onSegmentSelected: (segment) {
        setState(() {
          _selectedSegmentId = segment.id;
          _selectedOverlayId = null;
        });
      },
    );
  }

  Widget _buildBottomActions(AppLocalizations l10n) {
    final music = _project?.backgroundMusic;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        children: [
          if (music != null) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.music_note_outlined),
                title: Text(music.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: music.artist == null
                    ? null
                    : Text(music.artist!, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  onPressed: _exporting ? null : _removeMusic,
                  icon: const Icon(Icons.close),
                  tooltip: l10n.removeMusic,
                ),
              ),
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                onPressed: _exporting ? null : _addTextOverlay,
                icon: const Icon(Icons.text_fields),
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
                onPressed: _selectedSegmentId == null || _exporting
                    ? null
                    : _deleteSelectedSegment,
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
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting ? null : _exportAndSave,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(l10n.saveToGallery),
            ),
          ),
        ],
      ),
    );
  }
}
