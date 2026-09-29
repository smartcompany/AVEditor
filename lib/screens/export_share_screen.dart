import 'dart:async';
import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/youtube_upload_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/share_catalog_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Presented after Export. Shows encode progress, then the saved video
/// and the server-ordered share row.
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
  List<ShareTarget> _targets = ShareCatalogService.fallback;
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    _run();
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
      final path = await VideoThumbnail.thumbnailFile(
        video: widget.project.sourcePath,
        imageFormat: ImageFormat.JPEG,
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
      if (_cancelled || !mounted) return;
      await _save.saveExportedVideo(path);
      if (_cancelled || !mounted) return;
      debugPrint('[ExportShare] 앨범 저장 완료');
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

  Future<void> _onTarget(ShareTarget target) async {
    final path = _exportedPath;
    if (path == null) return;
    await _player?.pause();
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
    final uri = _share.appUri(target.kind);
    final opened = uri != null && await _share.openApp(uri);
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
        backgroundColor: const Color(0xFF161616),
        appBar: AppBar(
          backgroundColor: const Color(0xFF161616),
          title: Text(ready ? l10n.savedToDevice : l10n.exporting),
          actions: [
            if (ready)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.exportDone),
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
    final primary = _targets.first;
    final rest = _targets.skip(1);
    final language = Localizations.localeOf(context).languageCode;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          child: Column(
            children: [
              const Spacer(),
              _buildPlayer(),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => _onTarget(primary),
                  icon: _glyph(primary.kind, size: 22),
                  label: Text(
                    primary.labelFor(
                      language,
                      _fallbackLabel(l10n, primary.kind),
                    ),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final target in rest)
                    _iconButton(
                      label: target.labelFor(
                        language,
                        _fallbackLabel(l10n, target.kind),
                      ),
                      glyph: _glyph(target.kind, size: 26),
                      onTap: () => _onTarget(target),
                    ),
                  _iconButton(
                    label: l10n.shareMore,
                    glyph: const Icon(Icons.more_horiz, size: 26),
                    onTap: _shareMore,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    return GestureDetector(
      onTap: _togglePlay,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 132,
          height: 234,
          child: ColoredBox(
            color: Colors.black,
            child: ready
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: player.value.size.width,
                          height: player.value.size.height,
                          child: VideoPlayer(player),
                        ),
                      ),
                      if (!player.value.isPlaying)
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 52,
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
    );
  }

  Widget _iconButton({
    required String label,
    required Widget glyph,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3A),
                borderRadius: BorderRadius.circular(14),
              ),
              child: glyph,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFBDBDBD)),
            ),
          ],
        ),
      ),
    );
  }

  String _fallbackLabel(AppLocalizations l10n, ShareTargetKind kind) {
    return switch (kind) {
      ShareTargetKind.youtube => l10n.shareToYouTube,
      ShareTargetKind.instagram => 'Instagram',
      ShareTargetKind.facebook => 'Facebook',
      ShareTargetKind.whatsapp => 'WhatsApp',
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
      ShareTargetKind.whatsapp => Icon(
        Icons.chat,
        size: size,
        color: const Color(0xFF25D366),
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
                                      AppTheme.accent.withValues(alpha: 0.85),
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
                        color: Colors.white,
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
        ? const ColoredBox(color: Color(0xFF1C1C1C))
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
