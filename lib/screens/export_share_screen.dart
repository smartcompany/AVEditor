import 'dart:async';
import 'dart:io';

import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/tiktok_upload_screen.dart';
import 'package:aveditor/screens/youtube_upload_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:aveditor/services/review_prompt_service.dart';
import 'package:aveditor/services/share_catalog_service.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/services/video_import_service.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/widgets/video_thumbnail_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';

/// Share destinations after encode.
///
/// When [preparedExportPath] is set (export already finished in the editor),
/// skips the encode stage and opens the share UI immediately.
///
/// [ExportShareScreen.pickFromAlbum] opens the same share UI empty so the user
/// can choose a video from Photos first (home “share my content”).
class ExportShareScreen extends StatefulWidget {
  const ExportShareScreen({
    super.key,
    required this.project,
    this.preparedExportPath,
  }) : pickFromAlbum = false;

  /// Same destinations as post-export share; user picks the video from album.
  const ExportShareScreen.pickFromAlbum({super.key})
      : project = null,
        preparedExportPath = null,
        pickFromAlbum = true;

  final VideoProject? project;

  /// Absolute path of a finished export. Null → encode here (legacy), unless
  /// [pickFromAlbum] is true.
  final String? preparedExportPath;

  final bool pickFromAlbum;

  @override
  State<ExportShareScreen> createState() => _ExportShareScreenState();
}

class _ExportShareScreenState extends State<ExportShareScreen> {
  final _export = ExportService();
  final _save = ExportSaveService();
  final _settings = const AppSettingsService();
  final _catalog = ShareCatalogService();
  final _share = ExportShareService();
  final _projects = const ProjectStorageService();
  final _import = VideoImportService();
  final _probe = const VideoProbeService();

  double _progress = 0;
  var _cancelled = false;
  String? _thumbPath;
  String? _exportedPath;
  String? _error;
  var _savedToAlbum = false;
  var _savingToAlbum = false;
  var _pickingAlbum = false;

  /// iOS Photos asset id of the saved export, for handing to Instagram.
  String? _photosAssetId;
  List<ShareTarget> _targets = const [];
  VideoPlayerController? _player;

  /// Project for YouTube / thumbs. Album-pick fills this after a video is chosen.
  late VideoProject _project;

  /// True while a pre-exported file is loading into the share UI (no encode stage).
  late final bool _fromPrepared;
  late final bool _fromAlbumPick;
  var _preparingShareUi = false;

  @override
  void initState() {
    super.initState();
    _share.onFacebookResult = _onFacebookResult;
    _share.onTikTokResult = _onTikTokResult;
    _fromAlbumPick = widget.pickFromAlbum;
    _project = widget.project ??
        VideoProject(
          id: '_album_share',
          sourcePath: '',
          duration: Duration.zero,
        );
    final prepared = widget.preparedExportPath?.trim();
    _fromPrepared = prepared != null && prepared.isNotEmpty;
    _preparingShareUi = _fromPrepared;
    // Defer past initState — context.l10n / InheritedWidgets are not ready yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_fromPrepared) {
        unawaited(_openPrepared(prepared!));
      } else if (_fromAlbumPick) {
        unawaited(_warmCatalog());
      } else {
        unawaited(_run());
      }
    });
  }

  Future<void> _warmCatalog() async {
    try {
      final targets = await _catalog.load();
      if (!mounted) return;
      setState(() => _targets = targets);
    } catch (error, stack) {
      debugPrint('[ExportShare] catalog load failed: $error\n$stack');
    }
  }

  Future<void> _pickAlbumVideo() async {
    if (_pickingAlbum) return;
    setState(() {
      _pickingAlbum = true;
      _error = null;
    });
    try {
      final path = await _import.pickSingleVideoFromGallery();
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        setState(() => _pickingAlbum = false);
        return;
      }
      final project = await _projectForOriginalVideo(path);
      if (!mounted) return;
      setState(() {
        _pickingAlbum = false;
        _preparingShareUi = true;
        _exportedPath = null;
        _error = null;
        _project = project;
      });
      await _openPrepared(path);
    } catch (error, stack) {
      debugPrint('[ExportShare] album pick failed: $error\n$stack');
      if (!mounted) return;
      setState(() {
        _pickingAlbum = false;
        _preparingShareUi = false;
        _error = error.toString();
      });
    }
  }

  /// Album / re-share path: treat the picked file as a one-clip project so
  /// YouTube thumbnail scrubbing matches the post-export flow (original media).
  Future<VideoProject> _projectForOriginalVideo(String path) async {
    var duration = await _probe.readDuration(path) ?? Duration.zero;
    if (duration <= Duration.zero) {
      final probePlayer = VideoPlayerController.file(File(path));
      try {
        await probePlayer.initialize();
        duration = probePlayer.value.duration;
      } catch (error, stack) {
        debugPrint('[ExportShare] duration probe failed: $error\n$stack');
      } finally {
        await probePlayer.dispose();
      }
    }
    if (duration <= Duration.zero) {
      duration = const Duration(seconds: 1);
    }
    return VideoProject(
      id: '_album_share',
      sourcePath: path,
      duration: duration,
    );
  }

  Future<void> _openPrepared(String path) async {
    final catalogFuture = _catalog.load();
    final thumbFuture = _loadThumb();
    try {
      if (!_fromAlbumPick) {
        unawaited(_projects.markExported(_project.id));
        unawaited(RetentionNotificationService.instance.cancelDraftAbandon());
        if (mounted) {
          final l10n = context.l10n;
          unawaited(
            RetentionNotificationService.instance.scheduleShareNudge(
              projectId: _project.id,
              title: l10n.pushShareTitle,
              body: l10n.pushShareBody,
            ),
          );
        }
      }
      await thumbFuture;
      final targets = await catalogFuture;
      final player = VideoPlayerController.file(File(path));
      await player.initialize();
      await player.setLooping(true);
      if (!mounted) {
        await player.dispose();
        return;
      }
      // Prefer player duration when probe was short/wrong (album share).
      final played = player.value.duration;
      if (_fromAlbumPick &&
          played > Duration.zero &&
          (_project.duration - played).abs() > const Duration(milliseconds: 250)) {
        _project = VideoProject(
          id: '_album_share',
          sourcePath: path,
          duration: played,
        );
      }
      final previous = _player;
      setState(() {
        _exportedPath = path;
        _targets = targets;
        _player = player;
        _progress = 1;
        _preparingShareUi = false;
        _error = null;
        // Already from Photos — don't claim "saved" or duplicate the asset.
        if (_fromAlbumPick) _savedToAlbum = false;
      });
      await previous?.dispose();
      // Gallery save belongs with the share screen so the status line is true.
      if (!_fromAlbumPick) {
        unawaited(_saveToAlbumIfNeeded());
        unawaited(_maybeAskForReview());
      }
    } catch (error, stack) {
      debugPrint('[ExportShare] prepared open failed: $error\n$stack');
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _preparingShareUi = false;
      });
    }
  }

  void _onTikTokResult(String status, String? message) {
    if (!mounted) return;
    final l10n = context.l10n;
    const app = 'TikTok';
    final text = switch (status) {
      'posted' => l10n.shareAppPosted(app),
      'cancelled' => l10n.shareAppCancelled(app),
      _ => l10n.shareAppFailed(app, message ?? ''),
    };
    showLoggedSnackBar(
      context,
      text,
      error: status == 'failed' ? (message ?? status) : null,
      duration: Duration(seconds: status == 'failed' ? 8 : 3),
    );
  }

  void _onFacebookResult(String status, String? message) {
    if (!mounted) return;
    final l10n = context.l10n;
    final text = switch (status) {
      'posted' => l10n.shareFacebookPosted,
      'cancelled' => l10n.shareFacebookCancelled,
      _ => l10n.shareFacebookFailed(message ?? ''),
    };
    showLoggedSnackBar(
      context,
      text,
      error: status == 'failed' ? (message ?? status) : null,
      duration: Duration(seconds: status == 'failed' ? 8 : 3),
    );
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _loadThumb() async {
    final source = _project.sourcePath.trim();
    if (source.isEmpty) return;
    final segments = _project.segments;
    final timeMs = segments.isEmpty
        ? 0
        : segments.first.start.inMilliseconds +
              segments.first.duration.inMilliseconds ~/ 2;
    try {
      final path = await const VideoFrameGrab().jpegFile(
        video: source,
        timeMs: timeMs,
        maxHeight: 1280,
        quality: 85,
      );
      if (!mounted || path == null) return;
      setState(() => _thumbPath = path);
    } catch (error, stack) {
      debugPrint('[ExportShare] 썸네일 실패: $error\n$stack');
    }
  }

  Future<void> _run() async {
    final catalogFuture = _catalog.load();
    final thumbFuture = _loadThumb();
    try {
      final quality = await _settings.getExportQualityProfile();
      debugPrint('[ExportShare] 내보내기 시작 quality=${quality.name}');
      final started = DateTime.now();
      AnalyticsService.instance.log('export_started', {
        'quality': quality.name,
      });
      final path = await _export.exportToFile(
        _project,
        quality: quality,
        onProgress: (value) {
          final next = value.clamp(0.0, 1.0);
          if (!mounted) return;
          if ((next - _progress).abs() < 0.01 && next < 1) return;
          setState(() => _progress = next);
        },
      );
      debugPrint('[ExportShare] 내보내기 완료 path=$path');
      AnalyticsService.instance.log('export_completed', {
        'seconds': DateTime.now().difference(started).inSeconds,
      });
      unawaited(_projects.markExported(_project.id));
      unawaited(RetentionNotificationService.instance.cancelDraftAbandon());
      // Priority 2: nudge to share if they leave without posting.
      if (mounted) {
        final l10n = context.l10n;
        unawaited(
          RetentionNotificationService.instance.scheduleShareNudge(
            projectId: _project.id,
            title: l10n.pushShareTitle,
            body: l10n.pushShareBody,
          ),
        );
      }
      if (_cancelled || !mounted) return;
      await thumbFuture;
      final targets = await catalogFuture;
      final player = VideoPlayerController.file(File(path));
      await player.initialize();
      await player.setLooping(true);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _exportedPath = path;
        _targets = targets;
        _player = player;
        _progress = 1;
      });
      unawaited(_saveToAlbumIfNeeded());
      unawaited(_maybeAskForReview());
    } catch (error, stack) {
      final cancelled =
          _cancelled ||
          error.toString().contains('export_cancelled') ||
          error.toString().contains('save_cancelled');
      if (cancelled) {
        debugPrint('[ExportShare] 내보내기 취소됨');
        return;
      }
      debugPrint('[ExportShare] 실패: $error\n$stack');
      AnalyticsService.instance.log('export_failed');
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  /// Soft “enjoying?” then store review — only after a real export share screen.
  Future<void> _maybeAskForReview() async {
    if (_fromAlbumPick) return;
    await ReviewPromptService.instance.recordExportSuccess();
    if (!mounted) return;
    // Let the share UI settle so the prompt does not cover the progress stage.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || _error != null || _exportedPath == null) return;
    final l10n = context.l10n;
    await ReviewPromptService.instance.maybeAsk(
      context,
      title: l10n.reviewPromptTitle,
      body: l10n.reviewPromptBody,
      positiveLabel: l10n.reviewPromptYes,
      negativeLabel: l10n.reviewPromptNo,
    );
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    if (player.value.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
    if (mounted) setState(() {});
  }

  Future<bool> _saveToAlbumIfNeeded() async {
    final path = _exportedPath;
    if (path == null || _savingToAlbum) return false;
    if (_savedToAlbum) return true;
    // Album-picked videos are already in Photos; sharing uses the file path.
    if (_fromAlbumPick) return true;
    setState(() => _savingToAlbum = true);
    try {
      final assetId = await _save.saveExportedVideo(path);
      if (!mounted) return false;
      setState(() {
        _savedToAlbum = true;
        _photosAssetId = assetId;
      });
      debugPrint('[ExportShare] 앨범 저장 완료');
      return true;
    } catch (error, stack) {
      if (error.toString().contains('save_cancelled')) {
        debugPrint('[ExportShare] 앨범 저장 취소');
        return false;
      }
      debugPrint('[ExportShare] 앨범 저장 실패: $error\n$stack');
      if (!mounted) return false;
      final message = error.toString();
      final text = message.contains('photos_permission_denied')
          ? context.l10n.permissionPhotosDenied
          : context.l10n.exportFailedWithMessage(message);
      showLoggedSnackBar(context, text, error: error, stackTrace: stack);
      return false;
    } finally {
      if (mounted) setState(() => _savingToAlbum = false);
    }
  }

  Future<void> _onTarget(ShareTarget target) async {
    final path = _exportedPath;
    if (path == null) return;
    AnalyticsService.instance.log('share_target_tap', {
      'target': target.kind.name,
    });
    unawaited(RetentionNotificationService.instance.cancelShareNudge());
    await _player?.pause();
    if (!await _saveToAlbumIfNeeded() || !mounted) return;
    // YouTube: in-app API upload (no iOS share sheet — YouTube has no
    // public scheme to open Shorts create with a local file attached).
    if (target.kind == ShareTargetKind.youtube) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => YouTubeUploadScreen(
            project: _project,
            preparedExportPath: path,
          ),
        ),
      );
      return;
    }
    if (target.kind == ShareTargetKind.tiktok) {
      if (!mounted) return;
      // Direct Post form; the TikTok app hand-off stays as a fallback.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TikTokUploadScreen(
            videoPath: path,
            project: _project,
            onFinishInApp: () => _shareToTikTokApp(path),
          ),
        ),
      );
      return;
    }
    final opened = switch (target.kind) {
      ShareTargetKind.instagram => await _share.shareToInstagram(
        path: path,
        photosAssetId: _photosAssetId,
      ),
      ShareTargetKind.tiktok => await _share.shareToTikTok(
        path,
        photosAssetId: _photosAssetId,
      ),
      ShareTargetKind.facebook => await _share.shareToFacebook(
        path,
        photosAssetId: _photosAssetId,
      ),
      ShareTargetKind.youtube => false,
    };
    if (!opened && mounted) {
      showLoggedSnackBar(context, context.l10n.shareAppMissing);
    }
  }

  Future<void> _shareToTikTokApp(String path) async {
    final opened = await _share.shareToTikTok(
      path,
      photosAssetId: _photosAssetId,
    );
    if (!opened && mounted) {
      showLoggedSnackBar(context, context.l10n.shareAppMissing);
    }
  }

  Future<void> _shareMore() async {
    final path = _exportedPath;
    if (path == null) return;
    AnalyticsService.instance.log('share_more_tap');
    unawaited(RetentionNotificationService.instance.cancelShareNudge());
    await _player?.pause();
    if (!await _saveToAlbumIfNeeded() || !mounted) return;
    await _share.shareFile(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ready = _exportedPath != null && _error == null;
    // Prepared exports already finished encode in the editor — never show the
    // old conversion progress flash while the share player boots.
    final showShareChrome = ready || _fromPrepared || _fromAlbumPick;
    final title = showShareChrome ? l10n.shareContentTitle : l10n.exporting;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop || ready || _fromPrepared || _fromAlbumPick) return;
        _cancelExportWork();
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          title: Text(title),
          actions: [
            if (ready)
              IconButton(
                onPressed: _shareMore,
                tooltip: l10n.shareMore,
                icon: const Icon(Icons.ios_share),
              ),
          ],
        ),
        body: _fromAlbumPick
            ? (_preparingShareUi
                  ? const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  : _buildSaved(l10n))
            : ready
            ? _buildSaved(l10n)
            : _error != null
            ? _buildError(l10n)
            : _preparingShareUi
            ? const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _buildProgress(),
      ),
    );
  }

  void _cancelExportWork() {
    if (_cancelled || _exportedPath != null) return;
    _cancelled = true;
    debugPrint('[ExportShare] 내보내기 취소');
    unawaited(NativeVideoEngine.instance.cancelExport());
  }

  Widget _buildProgress() {
    return Center(
      child: _ConversionStage(thumbPath: _thumbPath, progress: _progress),
    );
  }

  Widget _buildError(AppLocalizations l10n) {
    final message = _error ?? '';
    final text = message.contains('photos_permission_denied')
        ? l10n.permissionPhotosDenied
        : message.contains('export_file_missing') ||
              message.contains('export_file_empty')
        ? l10n.exportFailed
        : l10n.exportFailedWithMessage(message);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaved(AppLocalizations l10n) {
    final language = Localizations.localeOf(context).languageCode;
    final ready = _exportedPath != null && _error == null;
    final buttons = [
      for (final target in _targets)
        _shareTile(
          label: target.labelFor(language, _fallbackLabel(l10n, target.kind)),
          subtitle: _shareSubtitle(l10n, target.kind),
          glyph: _glyph(target.kind, size: 28),
          onTap: ready ? () => _onTarget(target) : () {},
          enabled: ready,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            children: [
              // Preview + scrubber: in album mode, tap either to (re)pick.
              Expanded(child: _buildPlayer(l10n)),
              const SizedBox(height: 18),
              _buildScrubberArea(l10n),
              if (_savedToAlbum) ...[
                const SizedBox(height: 12),
                _SavedToDeviceLine(label: l10n.savedToDevice),
              ],
              if (_fromAlbumPick && _error != null) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.exportFailedWithMessage(_error!),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AppTheme.accent,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // Equal-weight 2×2 share grid (no YouTube-primary CTA).
              for (var i = 0; i < buttons.length; i += 2) ...[
                if (i > 0) const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: buttons[i]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: i + 1 < buttons.length
                          ? buttons[i + 1]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScrubberArea(AppLocalizations l10n) {
    final hasVideo = _player != null && _exportedPath != null;
    if (hasVideo && !_fromAlbumPick) {
      return VideoThumbnailScrubber(
        player: _player!,
        videoPath: _exportedPath!,
      );
    }
    if (hasVideo && _fromAlbumPick) {
      // Scrub works; a thin pick strip above keeps re-select obvious.
      return Column(
        children: [
          Material(
            color: AppTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: _pickingAlbum ? null : _pickAlbumVideo,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.photo_library_outlined,
                      size: 18,
                      color: AppTheme.ink.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.pickFromGallery,
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: AppTheme.ink.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          VideoThumbnailScrubber(
            player: _player!,
            videoPath: _exportedPath!,
          ),
        ],
      );
    }
    if (!_fromAlbumPick) return const SizedBox.shrink();
    return Material(
      color: AppTheme.surfaceElevated,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _pickingAlbum ? null : _pickAlbumVideo,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 56,
          child: Center(
            child: Text(
              l10n.sharePickFromAlbumHint,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.ink.withValues(alpha: 0.65),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayer(AppLocalizations l10n) {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final size = ready ? player.value.size : Size.zero;
    final aspect = ready && size.width > 0 && size.height > 0
        ? size.width / size.height
        : 9 / 16;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: ready
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _togglePlay,
                        child: VideoPlayer(player),
                      ),
                      if (!player.value.isPlaying)
                        Center(
                          child: GestureDetector(
                            onTap: _togglePlay,
                            child: const Icon(
                              Icons.play_circle_fill,
                              size: 64,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  )
                : _fromAlbumPick
                ? Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _pickingAlbum ? null : _pickAlbumVideo,
                      child: Center(
                        child: _pickingAlbum
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.video_library_outlined,
                                      size: 44,
                                      color: Colors.white.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      l10n.sharePickFromAlbumHint,
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.dmSans(
                                        fontSize: 14,
                                        height: 1.35,
                                        color: Colors.white.withValues(
                                          alpha: 0.9,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _shareTile({
    required String label,
    required Widget glyph,
    required VoidCallback onTap,
    String? subtitle,
    bool enabled = true,
  }) {
    final hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: hasSubtitle ? 64 : 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  glyph,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (hasSubtitle) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.ink.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ],
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

  String? _shareSubtitle(AppLocalizations l10n, ShareTargetKind kind) {
    return switch (kind) {
      ShareTargetKind.youtube => l10n.shareTileWithTikTok,
      ShareTargetKind.tiktok => l10n.shareTileWithYouTube,
      _ => null,
    };
  }

  String _fallbackLabel(AppLocalizations l10n, ShareTargetKind kind) {
    return switch (kind) {
      ShareTargetKind.youtube => 'YouTube',
      ShareTargetKind.instagram => 'Instagram',
      ShareTargetKind.facebook => 'Facebook',
      ShareTargetKind.tiktok => 'TikTok',
    };
  }

  Widget _glyph(ShareTargetKind kind, {required double size}) {
    return switch (kind) {
      ShareTargetKind.youtube => Icon(
        Icons.smart_display,
        size: size,
        color: const Color(0xFFFF0033),
      ),
      ShareTargetKind.instagram => Icon(
        Icons.photo_camera,
        size: size,
        color: const Color(0xFFE1306C),
      ),
      ShareTargetKind.facebook => Icon(
        Icons.facebook,
        size: size,
        color: const Color(0xFF1877F2),
      ),
      ShareTargetKind.tiktok => Icon(
        Icons.music_note,
        size: size,
        color: const Color(0xFFF5F5F5),
      ),
    };
  }
}

/// Compact confirmation that the export landed in Photos / gallery.
class _SavedToDeviceLine extends StatelessWidget {
  const _SavedToDeviceLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 16,
          color: AppTheme.accentCyan.withValues(alpha: 0.9),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppTheme.muted,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

/// Portrait frame that fills with the source still as export progresses.
class _ConversionStage extends StatefulWidget {
  const _ConversionStage({required this.thumbPath, required this.progress});

  final String? thumbPath;
  final double progress;

  @override
  State<_ConversionStage> createState() => _ConversionStageState();
}

class _ConversionStageState extends State<_ConversionStage>
    with SingleTickerProviderStateMixin {
  static const _width = 196.0;
  static const _height = 348.0;

  late final AnimationController _scan;

  @override
  void initState() {
    super.initState();
    _scan = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress.clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final thumb = widget.thumbPath;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppTheme.accent.withValues(alpha: 0.28),
                blurRadius: 28,
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: _width,
              height: _height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _still(thumb, dim: true),
                  if (progress >= 1)
                    _still(thumb, dim: false)
                  else if (progress > 0)
                    ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) {
                        final edge = progress.clamp(0.02, 0.98);
                        return LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: const [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                            Colors.transparent,
                          ],
                          stops: [0, edge - 0.01, edge, 1],
                        ).createShader(rect);
                      },
                      child: _still(thumb, dim: false),
                    ),
                  AnimatedBuilder(
                    animation: _scan,
                    builder: (context, _) {
                      final edge = progress * _height;
                      final sweep = _scan.value * _height;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            top: sweep - 36,
                            left: 0,
                            right: 0,
                            height: 72,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.white.withValues(alpha: 0.16),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (progress > 0 && progress < 1)
                            Positioned(
                              top: edge - 10,
                              left: 0,
                              right: 0,
                              height: 20,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.white.withValues(alpha: 0.95),
                                      AppTheme.gradientMagenta.withValues(
                                        alpha: 0.85,
                                      ),
                                      AppTheme.gradientCyan.withValues(
                                        alpha: 0.55,
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 14,
                    child: Text(
                      '$percent%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink,
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 12),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _still(String? path, {required bool dim}) {
    final image = path == null
        ? const ColoredBox(color: AppTheme.surfaceElevated)
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            width: _width,
            height: _height,
          );
    if (!dim) return image;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.45,
        0.15,
        0.05,
        0,
        0,
        0.05,
        0.45,
        0.05,
        0,
        0,
        0.05,
        0.10,
        0.40,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: Opacity(opacity: 0.55, child: image),
    );
  }
}
