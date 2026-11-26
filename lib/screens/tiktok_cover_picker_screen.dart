import 'dart:io';
import 'dart:typed_data';

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/video_filmstrip_cache.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';

/// Picks a cover frame for TikTok Direct Post (`video_cover_timestamp_ms`).
///
/// Pops with the selected time in milliseconds, or null if cancelled.
class TikTokCoverPickerScreen extends StatefulWidget {
  const TikTokCoverPickerScreen({
    super.key,
    required this.videoPath,
    this.initialMs = 0,
  });

  final String videoPath;
  final int initialMs;

  @override
  State<TikTokCoverPickerScreen> createState() =>
      _TikTokCoverPickerScreenState();
}

class _TikTokCoverPickerScreenState extends State<TikTokCoverPickerScreen> {
  static const _stripHeight = 58.0;
  static const _frameCount = 14;

  VideoPlayerController? _player;
  var _durationMs = 0;
  var _scrub = 0.0;
  var _dragging = false;
  var _heroRequest = 0;
  Uint8List? _hero;
  List<Uint8List?> _frames = const [];

  int get _scrubMs {
    if (_durationMs <= 0) return 0;
    // TikTok cover must be within the video; keep off the very last ms.
    final maxMs = (_durationMs - 1).clamp(0, _durationMs);
    return (_durationMs * _scrub).round().clamp(0, maxMs);
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final player = VideoPlayerController.file(File(widget.videoPath));
    try {
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      final durationMs = player.value.duration.inMilliseconds;
      final maxMs = (durationMs - 1).clamp(0, durationMs);
      final initial = widget.initialMs.clamp(0, maxMs);
      final scrub = durationMs <= 0 ? 0.0 : initial / durationMs;
      setState(() {
        _player = player;
        _durationMs = durationMs;
        _scrub = scrub;
      });
      await _loadStrip();
      if (mounted) await _loadHero();
    } catch (error, stack) {
      debugPrint('[TikTokCover] open failed: $error\n$stack');
      await player.dispose();
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _loadStrip() async {
    final times = _frameTimes();
    final frames = List<Uint8List?>.filled(times.length, null);
    if (!mounted) return;

    for (var i = 0; i < times.length; i++) {
      final hit = VideoFilmstripCache.instance.peek(
        video: widget.videoPath,
        timeMs: times[i],
        maxHeight: VideoFilmstripCache.stripMaxHeight,
        quality: VideoFilmstripCache.stripQuality,
      );
      if (hit != null) frames[i] = hit;
    }
    if (frames.any((f) => f != null)) {
      setState(() => _frames = List<Uint8List?>.of(frames));
    }

    await VideoFilmstripCache.instance.loadTimes(
      video: widget.videoPath,
      timesMs: times,
      maxHeight: VideoFilmstripCache.stripMaxHeight,
      maxWidth: VideoFilmstripCache.stripMaxHeight,
      quality: VideoFilmstripCache.stripQuality,
      concurrency: 4,
      onFrame: (index, bytes) {
        if (!mounted) return;
        frames[index] = bytes;
        setState(() => _frames = List<Uint8List?>.of(frames));
      },
    );
  }

  List<int> _frameTimes() {
    final total = _durationMs;
    if (total <= 0) return const [0];
    if (_frameCount <= 1) return const [0];
    return [
      for (var i = 0; i < _frameCount; i++)
        (total * i / (_frameCount - 1)).round().clamp(0, total),
    ];
  }

  Future<void> _loadHero() async {
    final request = ++_heroRequest;
    final ms = _scrubMs;
    final bytes = await VideoFilmstripCache.instance.getBytes(
      video: widget.videoPath,
      timeMs: ms,
      maxHeight: 720,
      maxWidth: 720,
      quality: 82,
    );
    if (!mounted || request != _heroRequest) return;
    if (bytes == null || bytes.isEmpty) return;
    setState(() => _hero = bytes);
    await _player?.seekTo(Duration(milliseconds: ms));
  }

  void _confirm() {
    Navigator.of(context).pop(_scrubMs);
  }

  String _format(int ms) {
    final total = Duration(milliseconds: ms);
    final minutes = total.inMinutes;
    final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final still = _hero;
    final ready = _player != null && _durationMs > 0;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(l10n.uploadThumbnailSelect),
        actions: [
          TextButton(
            onPressed: ready ? _confirm : null,
            child: Text(
              l10n.exportDone,
              style: GoogleFonts.dmSans(
                fontWeight: FontWeight.w700,
                color: ready ? AppTheme.accentCyan : AppTheme.muted,
              ),
            ),
          ),
        ],
      ),
      body: !ready
          ? const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: ColoredBox(
                            color: Colors.black,
                            child: still == null
                                ? const Center(
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : Image.memory(
                                    still,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        _format(_scrubMs),
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: _dragging ? AppTheme.ink : AppTheme.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _format(_durationMs),
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: _buildStrip(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStrip() {
    final travel = MediaQuery.sizeOf(context).width - 24;
    return SizedBox(
      height: _stripHeight + 12,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final next = (details.localPosition.dx / width).clamp(0.0, 1.0);
              setState(() => _scrub = next);
              _loadHero();
            },
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (details) {
              final next =
                  (_scrub + details.delta.dx / travel).clamp(0.0, 1.0);
              setState(() => _scrub = next);
            },
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              _loadHero();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragging = false);
              _loadHero();
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 6,
                  height: _stripHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Row(
                      children: [
                        for (var i = 0; i < _frameCount; i++)
                          Expanded(
                            child: i < _frames.length && _frames[i] != null
                                ? Image.memory(
                                    _frames[i]!,
                                    fit: BoxFit.cover,
                                    height: _stripHeight,
                                    gaplessPlayback: true,
                                  )
                                : const ColoredBox(
                                    color: AppTheme.surfaceElevated,
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: (width * _scrub - 2).clamp(0.0, width - 4),
                  top: 0,
                  bottom: 0,
                  width: 4,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
