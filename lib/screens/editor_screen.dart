import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/youtube_upload_screen.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/widgets/export_progress_dialog.dart';
import 'package:aveditor/widgets/text_overlay_editor_sheet.dart';
import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:aveditor/utils/overlay_event_log.dart';
import 'package:aveditor/widgets/overflow_hit_stack.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.videoPath});

  final String videoPath;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  VideoPlayerController? _controller;
  VideoProject? _project;
  String? _selectedOverlayId;

  /// Overlay currently edited inline on the preview (keyboard open).
  String? _editingOverlayId;
  bool _ready = false;
  bool _exporting = false;
  String? _errorMessage;

  /// Optimistic playhead while `seekTo` is in flight (avoids timeline jitter).
  Duration? _scrubPlayhead;

  final _export = ExportService();
  final _exportSave = ExportSaveService();
  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();

  Duration get _playhead {
    return _scrubPlayhead ?? _controller?.value.position ?? Duration.zero;
  }

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final controller = VideoPlayerController.file(File(widget.videoPath));
      await controller.initialize();
      controller.setLooping(false);
      controller.addListener(_onVideoTick);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      final duration = controller.value.duration;
      setState(() {
        _controller = controller;
        _project = VideoProject(
          sourcePath: widget.videoPath,
          duration: duration,
          trim: ClipTrim(start: Duration.zero, end: duration),
        );
        _ready = true;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _errorMessage = e.toString();
      });
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
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
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

    final clamped = clampDuration(
      position,
      project.trim.start,
      project.trim.end,
    );
    _scrubPlayhead = clamped;
    controller.seekTo(clamped);
    setState(() {});
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
          controller.value.position < project.trim.start) {
        controller.seekTo(project.trim.start);
      }
      controller.play();
    }
    setState(() {});
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
    setState(() {
      project.overlays.add(overlay);
      _selectedOverlayId = overlay.id;
      _editingOverlayId = overlay.id;
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

    setState(() {
      project.overlays.removeWhere((o) => o.id == id);
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
      final exportedPath = await _export.exportForPreset(
        project,
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
            child: Text(l10n.videoLoadError, textAlign: TextAlign.center),
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
                            position: _playhead,
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
                            onOverlayTextChanged: _onOverlayTextChanged,
                            onEditingComplete: _finishInlineEditing,
                            onOverlayOffsetChanged: (overlay, offset) {
                              _patchOverlay(
                                overlay.id,
                                (current) => current.copyWith(offset: offset),
                              );
                            },
                            onOverlayBoxChanged:
                                (overlay, width, height, offset) {
                                  OverlayEventLog.log(
                                    'Editor',
                                    'overlayBoxChanged',
                                    {
                                      'id': overlay.id,
                                      'width': width.toStringAsFixed(1),
                                      'height': height.toStringAsFixed(1),
                                      'offset': offset,
                                    },
                                  );
                                  _patchOverlay(
                                    overlay.id,
                                    (current) => current.copyWith(
                                      boxWidth: width,
                                      boxHeight: height,
                                      offset: offset,
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
          if (isInlineEditing)
            Listener(
              onPointerDown: (_) =>
                  _finishInlineEditing('timeline_pointer_down'),
              behavior: HitTestBehavior.translucent,
              child: _buildTimeline(project: project, controller: controller),
            )
          else
            _buildTimeline(project: project, controller: controller),
          const SizedBox(height: 8),
          if (isInlineEditing)
            Listener(
              onPointerDown: (_) =>
                  _finishInlineEditing('bottom_bar_pointer_down'),
              behavior: HitTestBehavior.translucent,
              child: _buildBottomActions(l10n),
            )
          else
            _buildBottomActions(l10n),
        ],
      ),
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
      overlays: project.overlays,
      playhead: _playhead,
      isPlaying: controller.value.isPlaying,
      onTogglePlay: _togglePlay,
      selectedOverlayId: _selectedOverlayId,
      onPlayheadChanged: _seek,
      onTrimStartChanged: (start) {
        setState(() => project.trim = project.trim.copyWith(start: start));
        if (_playhead < start) {
          _seek(start);
        }
      },
      onTrimEndChanged: (end) {
        setState(() => project.trim = project.trim.copyWith(end: end));
        if (_playhead > end) {
          _seek(end);
        }
      },
      onOverlayChanged: _updateOverlay,
      onOverlaySelected: (overlay) {
        setState(() => _selectedOverlayId = overlay.id);
      },
    );
  }

  Widget _buildBottomActions(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _addTextOverlay,
                  icon: const Icon(Icons.title),
                  label: Text(l10n.addText),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectedOverlay == null || _exporting
                      ? null
                      : _editSelectedOverlay,
                  icon: const Icon(Icons.tune),
                  label: Text(l10n.editText),
                ),
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
