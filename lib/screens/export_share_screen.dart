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
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/share_catalog_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/video_thumbnail_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:video_player/video_player.dart';

/// Presented after Export. Shows encode progress, then the video and the
/// server-ordered share row. The photo album is updated only when a share
/// target is chosen.
class ExportShareScreen extends StatefulWidget {
  const ExportShareScreen({super.key, required this.project});

  final VideoProject project;

  @override
  State<ExportShareScreen> createState() => _ExportShareScreenState();
}

class _ExportShareScreenState extends State<ExportShareScreen> {
  final _export = ExportService();
  final _save = ExportSaveService();
  final _settings = const AppSettingsService();
  final _catalog = ShareCatalogService();
  final _share = ExportShareService();

  double _progress = 0;
  var _cancelled = false;
  String? _thumbPath;
  String? _exportedPath;
  String? _error;
  var _savedToAlbum = false;
  var _savingToAlbum = false;

  /// iOS Photos asset id of the saved export, for handing to Instagram.
  String? _photosAssetId;
  List<ShareTarget> _targets = ShareCatalogService.fallback;
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    _share.onFacebookResult = _onFacebookResult;
    _share.onTikTokResult = _onTikTokResult;
    _run();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: status == 'failed' ? 8 : 3),
      ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: status == 'failed' ? 8 : 3),
      ),
    );
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _loadThumb() async {
    final segments = widget.project.segments;
    final timeMs = segments.isEmpty
        ? 0
        : segments.first.start.inMilliseconds +
              segments.first.duration.inMilliseconds ~/ 2;
    try {
      final path = await const VideoFrameGrab().jpegFile(
        video: widget.project.sourcePath,
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
        widget.project,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      return false;
    } finally {
      if (mounted) setState(() => _savingToAlbum = false);
    }
  }

  Future<void> _onTarget(ShareTarget target) async {
    final path = _exportedPath;
    if (path == null) return;
    await _player?.pause();
    if (!await _saveToAlbumIfNeeded() || !mounted) return;
    if (target.kind == ShareTargetKind.youtube) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => YouTubeUploadScreen(
            project: widget.project,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.shareAppMissing)));
    }
  }

  Future<void> _shareToTikTokApp(String path) async {
    final opened = await _share.shareToTikTok(
      path,
      photosAssetId: _photosAssetId,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.shareAppMissing)));
    }
  }

  Future<void> _shareMore() async {
    final path = _exportedPath;
    if (path == null) return;
    await _player?.pause();
    if (!await _saveToAlbumIfNeeded() || !mounted) return;
    await _share.shareFile(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ready = _exportedPath != null && _error == null;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop || ready) return;
        _cancelExportWork();
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          title: Text(
            ready
                ? (_savedToAlbum ? l10n.savedToDevice : l10n.exportComplete)
                : l10n.exporting,
          ),
          actions: [
            if (ready)
              IconButton(
                onPressed: _shareMore,
                tooltip: l10n.shareMore,
                icon: const Icon(Icons.ios_share),
              ),
          ],
        ),
        body: ready
            ? _buildSaved(l10n)
            : _error != null
            ? _buildError(l10n)
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
      child: Padding(
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
    final buttons = [
      for (final target in _targets)
        _shareTile(
          label: target.labelFor(language, _fallbackLabel(l10n, target.kind)),
          glyph: _glyph(target.kind, size: 28),
          onTap: () => _onTarget(target),
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
              // The video takes all the room the share buttons leave.
              Expanded(child: _buildPlayer()),
              if (_player != null && _exportedPath != null) ...[
                const SizedBox(height: 18),
                VideoThumbnailScrubber(
                  player: _player!,
                  videoPath: _exportedPath!,
                ),
              ],
              const SizedBox(height: 20),
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

  Widget _buildPlayer() {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final size = ready ? player.value.size : Size.zero;
    final aspect = ready && size.width > 0 && size.height > 0
        ? size.width / size.height
        : 9 / 16;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: GestureDetector(
          onTap: _togglePlay,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Colors.black,
              child: ready
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoPlayer(player),
                        if (!player.value.isPlaying)
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              size: 64,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    )
                  : const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
  }) {
    return Material(
      color: AppTheme.surfaceElevated,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                glyph,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
