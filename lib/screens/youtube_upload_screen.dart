import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class YouTubeUploadScreen extends StatefulWidget {
  const YouTubeUploadScreen({
    super.key,
    required this.project,
    this.preparedExportPath,
  });

  final VideoProject project;

  /// Exported file from the share screen. Skips a second encode when set.
  final String? preparedExportPath;

  @override
  State<YouTubeUploadScreen> createState() => _YouTubeUploadScreenState();
}

class _YouTubeUploadScreenState extends State<YouTubeUploadScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController(text: '#Shorts');
  String _privacy = 'public';
  bool _madeForKids = false;
  bool _ageRestricted = false;
  bool _busy = false;
  String? _thumbnailPath;
  List<String> _framePaths = const [];
  bool _framesLoading = true;
  String? _playlistId;
  List<YouTubePlaylist> _playlists = const [];
  bool _playlistsLoading = false;
  String? _playlistsError;

  VideoPlayerController? _preview;
  var _segmentIndex = 0;
  var _advancingSegment = false;
  var _previewFailed = false;

  final _export = ExportService();
  final _upload = YouTubeUploadService();
  final _auth = YouTubeAuthService();
  final _settings = const AppSettingsService();
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _openPreview();
    _loadFrames();
  }

  @override
  void dispose() {
    _preview?.removeListener(_onPreviewTick);
    _preview?.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  List<ClipSegment> get _segments => widget.project.segments;

  Future<void> _openPreview() async {
    final controller = VideoPlayerController.file(
      File(widget.project.sourcePath),
    );
    _preview = controller;
    try {
      await controller.initialize();
      await controller.setLooping(false);
      final start = _segments.isEmpty ? Duration.zero : _segments.first.start;
      await controller.seekTo(start);
      controller.addListener(_onPreviewTick);
      if (!mounted) return;
      setState(() {});
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 미리보기 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _previewFailed = true);
    }
  }

  void _onPreviewTick() {
    final controller = _preview;
    if (controller == null ||
        _advancingSegment ||
        !controller.value.isPlaying ||
        _segments.isEmpty) {
      return;
    }
    final index = _segmentIndex.clamp(0, _segments.length - 1);
    final segment = _segments[index];
    if (controller.value.position <
        segment.end - const Duration(milliseconds: 80)) {
      return;
    }
    _advancingSegment = true;
    if (index + 1 < _segments.length) {
      _segmentIndex = index + 1;
      controller.seekTo(_segments[_segmentIndex].start).whenComplete(() {
        _advancingSegment = false;
      });
      return;
    }
    _segmentIndex = 0;
    controller.pause();
    controller.seekTo(_segments.first.start).whenComplete(() {
      _advancingSegment = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _togglePreview() async {
    final controller = _preview;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (_segments.isNotEmpty &&
          controller.value.position >= _segments.last.end) {
        _segmentIndex = 0;
        await controller.seekTo(_segments.first.start);
      }
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadFrames() async {
    try {
      final times = _thumbnailTimes();
      final paths = <String>[];
      for (final timeMs in times) {
        final path = await VideoThumbnail.thumbnailFile(
          video: widget.project.sourcePath,
          imageFormat: ImageFormat.JPEG,
          timeMs: timeMs,
          maxHeight: 720,
          quality: 80,
        );
        if (path != null) paths.add(path);
      }
      if (!mounted) return;
      setState(() => _framePaths = paths);
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 썸네일 프레임 실패: $error\n$stack');
    } finally {
      if (mounted) setState(() => _framesLoading = false);
    }
  }

  List<int> _thumbnailTimes() {
    const count = 8;
    if (_segments.isEmpty) return const [0];
    final total = widget.project.trimmedDuration.inMilliseconds;
    if (total <= 0) return [_segments.first.start.inMilliseconds];
    return [
      for (var i = 0; i < count; i++)
        _sourceMsForTimeline((total * i / count).round()),
    ];
  }

  int _sourceMsForTimeline(int timelineMs) {
    var cursor = 0;
    for (final segment in _segments) {
      final length = segment.duration.inMilliseconds;
      if (length <= 0) continue;
      if (timelineMs < cursor + length) {
        return segment.start.inMilliseconds + (timelineMs - cursor);
      }
      cursor += length;
    }
    return _segments.last.end.inMilliseconds - 1;
  }

  Future<void> _pickThumbnailPhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1280,
    );
    if (file == null || !mounted) return;
    setState(() => _thumbnailPath = file.path);
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _playlistsLoading = true;
      _playlistsError = null;
    });
    try {
      if (!await _auth.isSignedIn) {
        await _auth.signIn();
      }
      await _auth.ensureAccountScope();
      final token = await _auth.accessToken();
      final playlists = await _upload.listPlaylists(token);
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 재생목록 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _playlistsError = context.l10n.uploadPlaylistFailed);
    } finally {
      if (mounted) setState(() => _playlistsLoading = false);
    }
  }

  Future<void> _pickPlaylist() async {
    if (_playlists.isEmpty && !_playlistsLoading) {
      await _loadPlaylists();
      if (!mounted || _playlistsError != null) return;
    }
    if (!mounted) return;
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(l10n.uploadPlaylistNone),
                  trailing: _playlistId == null
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, ''),
                ),
                for (final playlist in _playlists)
                  ListTile(
                    title: Text(playlist.title),
                    trailing: _playlistId == playlist.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, playlist.id),
                  ),
                if (_playlists.isEmpty)
                  ListTile(title: Text(l10n.uploadPlaylistEmpty)),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null) return;
    setState(() => _playlistId = selected.isEmpty ? null : selected);
  }

  String _playlistLabel(AppLocalizations l10n) {
    if (_playlistId == null) return l10n.uploadPlaylistNone;
    for (final playlist in _playlists) {
      if (playlist.id == _playlistId) return playlist.title;
    }
    return l10n.uploadPlaylistNone;
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.uploadTitleHint)));
      return;
    }

    setState(() => _busy = true);
    await _preview?.pause();
    debugPrint(
      '[YouTubeUpload] 시작 title="${_titleController.text.trim()}" '
      'privacy=$_privacy kids=$_madeForKids ageRestricted=$_ageRestricted '
      'playlist=${_playlistId ?? "none"} '
      'thumbnail=${_thumbnailPath == null ? "auto" : "custom"}',
    );
    String? videoId;
    try {
      final signedIn = await _auth.isSignedIn;
      debugPrint(
        signedIn ? '[YouTubeUpload] 이미 로그인됨' : '[YouTubeUpload] 로그인 필요',
      );
      if (!signedIn) {
        await _auth.signIn();
        debugPrint('[YouTubeUpload] 로그인 완료');
      }
      if (_playlistId != null || _ageRestricted) {
        await _auth.ensureAccountScope();
      }
      debugPrint('[YouTubeUpload] 액세스 토큰 요청');
      final token = await _auth.accessToken();
      debugPrint('[YouTubeUpload] 액세스 토큰 준비됨');
      final prepared = widget.preparedExportPath;
      final String path;
      if (prepared != null && await File(prepared).exists()) {
        path = prepared;
        debugPrint('[YouTubeUpload] 이미 보낸 파일 사용 path=$path');
      } else {
        final quality = await _settings.getExportQualityProfile();
        debugPrint('[YouTubeUpload] 내보내기 시작 quality=${quality.name}');
        var lastExportBucket = -1;
        path = await _export.exportForPreset(
          widget.project,
          quality: quality,
          onProgress: (progress) {
            final percent = (progress.clamp(0.0, 1.0) * 100).round();
            final bucket = percent ~/ 10;
            if (bucket == lastExportBucket) return;
            lastExportBucket = bucket;
            debugPrint('[YouTubeUpload] 내보내기 $percent%');
          },
        );
        debugPrint('[YouTubeUpload] 내보내기 완료 path=$path');
      }
      videoId = await _upload.uploadProject(
        project: widget.project,
        exportedPath: path,
        accessToken: token,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        privacyStatus: _privacy,
        madeForKids: _madeForKids,
      );
      debugPrint('[YouTubeUpload] 업로드 완료 videoId=$videoId');
      final followUp = await _applyDetails(token: token, videoId: videoId);
      if (!mounted) return;
      if (followUp != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.uploadPartialFailure(videoId, followUp))),
        );
      }
      Navigator.of(context).pop();
    } catch (e, stack) {
      debugPrint('[YouTubeUpload] 실패: $e\n$stack');
      if (!mounted) return;
      if (videoId != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.uploadPartialFailure(videoId, e.toString())),
          ),
        );
        Navigator.of(context).pop();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.exportFailedWithMessage(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _applyDetails({
    required String token,
    required String videoId,
  }) async {
    final errors = <String>[];
    final thumbnail = _thumbnailPath;
    if (thumbnail != null) {
      try {
        await _upload.setThumbnail(
          accessToken: token,
          videoId: videoId,
          imagePath: thumbnail,
        );
      } catch (error) {
        errors.add('$error');
      }
    }
    final playlistId = _playlistId;
    if (playlistId != null) {
      try {
        await _upload.addToPlaylist(
          accessToken: token,
          videoId: videoId,
          playlistId: playlistId,
        );
      } catch (error) {
        errors.add('$error');
      }
    }
    if (_ageRestricted && !_madeForKids) {
      try {
        await _upload.setAgeRestricted(accessToken: token, videoId: videoId);
      } catch (error) {
        errors.add('$error');
      }
    }
    if (errors.isEmpty) return null;
    return errors.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.uploadShorts)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Center(child: _buildPreview(l10n, preview)),
          const SizedBox(height: 20),
          TextField(
            controller: _titleController,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: l10n.uploadTitleHint),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(labelText: l10n.uploadDescriptionHint),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.uploadThumbnail,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildThumbnailChoices(l10n),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _privacy,
            decoration: InputDecoration(labelText: l10n.uploadVisibility),
            items: [
              DropdownMenuItem(
                value: 'public',
                child: Text(l10n.privacyPublic),
              ),
              DropdownMenuItem(
                value: 'unlisted',
                child: Text(l10n.privacyUnlisted),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text(l10n.privacyPrivate),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) setState(() => _privacy = value);
                  },
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.uploadPlaylist),
            subtitle: Text(_playlistsError ?? _playlistLabel(l10n)),
            trailing: _playlistsLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _pickPlaylist,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.uploadAudience,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.uploadAudienceHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(
                  l10n.uploadAudienceNotForKids,
                  textAlign: TextAlign.center,
                ),
              ),
              ButtonSegment(
                value: true,
                label: Text(
                  l10n.uploadAudienceForKids,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            selected: {_madeForKids},
            onSelectionChanged: _busy
                ? null
                : (selection) {
                    setState(() {
                      _madeForKids = selection.first;
                      if (_madeForKids) _ageRestricted = false;
                    });
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.uploadAgeRestriction),
            subtitle: Text(l10n.uploadAgeRestrictionHelp),
            value: _ageRestricted && !_madeForKids,
            onChanged: _busy || _madeForKids
                ? null
                : (value) => setState(() => _ageRestricted = value),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.uploadShorts),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(AppLocalizations l10n, VideoPlayerController? preview) {
    final ready =
        preview != null && preview.value.isInitialized && !_previewFailed;
    return SizedBox(
      height: 320,
      width: 180,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: AppTheme.surface,
          child: ready
              ? GestureDetector(
                  onTap: _busy ? null : _togglePreview,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: preview.value.size.width,
                          height: preview.value.size.height,
                          child: VideoPlayer(preview),
                        ),
                      ),
                      if (!preview.value.isPlaying)
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 56,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                )
              : Center(
                  child: _previewFailed
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            l10n.videoLoadError,
                            textAlign: TextAlign.center,
                          ),
                        )
                      : const CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      ),
    );
  }

  Widget _buildThumbnailChoices(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 72,
          child: _framesLoading
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _thumbnailTile(
                      label: l10n.uploadThumbnailAuto,
                      selected: _thumbnailPath == null,
                      onTap: () => setState(() => _thumbnailPath = null),
                    ),
                    for (final path in _framePaths)
                      _thumbnailTile(
                        imagePath: path,
                        selected: _thumbnailPath == path,
                        onTap: () => setState(() => _thumbnailPath = path),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickThumbnailPhoto,
          icon: const Icon(Icons.photo_outlined),
          label: Text(l10n.uploadThumbnailFromPhoto),
        ),
        if (_thumbnailPath != null && !_framePaths.contains(_thumbnailPath))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(_thumbnailPath!),
                height: 96,
                fit: BoxFit.cover,
              ),
            ),
          ),
      ],
    );
  }

  Widget _thumbnailTile({
    String? label,
    String? imagePath,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: _busy ? null : onTap,
        child: Container(
          width: 54,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? AppTheme.accent
                  : AppTheme.muted.withValues(alpha: 0.4),
              width: selected ? 2 : 1,
            ),
            image: imagePath == null
                ? null
                : DecorationImage(
                    image: FileImage(File(imagePath)),
                    fit: BoxFit.cover,
                  ),
          ),
          child: label == null
              ? null
              : Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
        ),
      ),
    );
  }
}
