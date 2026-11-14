import 'dart:typed_data';

import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Filmstrip of frames from [videoPath] with a playhead. Tap or drag to seek
/// [player]; playback pauses while dragging and resumes afterwards.
class VideoThumbnailScrubber extends StatefulWidget {
  const VideoThumbnailScrubber({
    super.key,
    required this.player,
    required this.videoPath,
    this.frameCount = 10,
    this.height = 52,
  });

  final VideoPlayerController player;
  final String videoPath;
  final int frameCount;
  final double height;

  /// Position for a touch at [dx] on a strip [width] wide.
  @visibleForTesting
  static Duration positionAt(double dx, double width, Duration duration) {
    if (width <= 0 || duration <= Duration.zero) return Duration.zero;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return Duration(microseconds: (duration.inMicroseconds * fraction).round());
  }

  /// Times to grab, one at the middle of each equal slice.
  @visibleForTesting
  static List<int> frameTimesMs(Duration duration, int count) {
    if (count <= 0 || duration <= Duration.zero) return const [];
    final ms = duration.inMilliseconds;
    return [for (var i = 0; i < count; i++) ((i + 0.5) * ms / count).round()];
  }

  @override
  State<VideoThumbnailScrubber> createState() => _VideoThumbnailScrubberState();
}

class _VideoThumbnailScrubberState extends State<VideoThumbnailScrubber> {
  late List<Uint8List?> _frames = List.filled(widget.frameCount, null);
  bool _dragging = false;
  bool _resumeAfterDrag = false;

  /// Shown while dragging so the handle follows the finger even before the
  /// player reports the new position.
  Duration? _dragPosition;

  @override
  void initState() {
    super.initState();
    _loadFrames();
  }

  @override
  void didUpdateWidget(covariant VideoThumbnailScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath ||
        oldWidget.frameCount != widget.frameCount) {
      _frames = List.filled(widget.frameCount, null);
      _loadFrames();
    }
  }

  Future<void> _loadFrames() async {
    final path = widget.videoPath;
    final times = VideoThumbnailScrubber.frameTimesMs(
      widget.player.value.duration,
      widget.frameCount,
    );
    const grab = VideoFrameGrab();
    for (var i = 0; i < times.length; i++) {
      try {
        final bytes = await grab.jpegBytes(
          video: path,
          timeMs: times[i],
          maxHeight: (widget.height * 3).round(),
          quality: 70,
        );
        if (!mounted || path != widget.videoPath) return;
        if (bytes != null) setState(() => _frames[i] = bytes);
      } catch (error) {
        debugPrint('[Scrubber] 프레임 실패 ${times[i]}ms: $error');
      }
    }
  }

  Future<void> _seekTo(double dx, double width) async {
    final target = VideoThumbnailScrubber.positionAt(
      dx,
      width,
      widget.player.value.duration,
    );
    setState(() => _dragPosition = target);
    await widget.player.seekTo(target);
  }

  Future<void> _startDrag() async {
    _dragging = true;
    _resumeAfterDrag = widget.player.value.isPlaying;
    if (_resumeAfterDrag) await widget.player.pause();
  }

  Future<void> _endDrag() async {
    _dragging = false;
    if (_resumeAfterDrag) await widget.player.play();
    _resumeAfterDrag = false;
    if (mounted) setState(() => _dragPosition = null);
  }

  String _format(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.player,
      builder: (context, value, _) {
        final duration = value.duration;
        final position = _dragPosition ?? value.position;
        final fraction = duration.inMicroseconds <= 0
            ? 0.0
            : (position.inMicroseconds / duration.inMicroseconds).clamp(
                0.0,
                1.0,
              );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  key: const Key('video-thumbnail-scrubber'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _seekTo(details.localPosition.dx, width),
                  onHorizontalDragStart: (details) async {
                    await _startDrag();
                    await _seekTo(details.localPosition.dx, width);
                  },
                  onHorizontalDragUpdate: (details) =>
                      _seekTo(details.localPosition.dx, width),
                  onHorizontalDragEnd: (_) => _endDrag(),
                  onHorizontalDragCancel: _endDrag,
                  child: SizedBox(
                    height: widget.height + 8,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 4,
                          height: widget.height,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              children: [
                                for (final frame in _frames)
                                  Expanded(
                                    child: frame == null
                                        ? const ColoredBox(
                                            color: AppTheme.surfaceElevated,
                                          )
                                        : Image.memory(
                                            frame,
                                            fit: BoxFit.cover,
                                            height: widget.height,
                                            gaplessPlayback: true,
                                          ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // Played part stays bright; the rest is dimmed.
                        Positioned(
                          left: width * fraction,
                          right: 0,
                          top: 4,
                          height: widget.height,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.horizontal(
                                  left: fraction <= 0
                                      ? const Radius.circular(8)
                                      : Radius.zero,
                                  right: const Radius.circular(8),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: (width * fraction - 2).clamp(0.0, width - 4),
                          top: 0,
                          bottom: 0,
                          width: 4,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black54,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  _format(position),
                  style: TextStyle(
                    fontSize: 12,
                    color: _dragging ? AppTheme.ink : AppTheme.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                Text(
                  _format(duration),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.muted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
