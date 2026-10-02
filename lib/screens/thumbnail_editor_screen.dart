import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/widgets/basic_text_edit_toolbar.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Full-screen still picker. Returns the composed thumbnail file path.
class ThumbnailEditorScreen extends StatefulWidget {
  const ThumbnailEditorScreen({super.key, required this.project});

  final VideoProject project;

  @override
  State<ThumbnailEditorScreen> createState() => _ThumbnailEditorScreenState();
}

class _ThumbFilter {
  const _ThumbFilter(this.matrix);

  final List<double>? matrix;
}

const _filters = <_ThumbFilter>[
  _ThumbFilter(null),
  _ThumbFilter(<double>[
    1.2,
    0,
    0,
    0,
    12,
    0,
    1.05,
    0,
    0,
    0,
    0,
    0,
    0.85,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  _ThumbFilter(<double>[
    0.85,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1.2,
    0,
    12,
    0,
    0,
    0,
    1,
    0,
  ]),
  _ThumbFilter(<double>[
    1.35,
    -0.15,
    -0.15,
    0,
    0,
    -0.15,
    1.35,
    -0.15,
    0,
    0,
    -0.15,
    -0.15,
    1.35,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  _ThumbFilter(<double>[
    0.33,
    0.33,
    0.33,
    0,
    0,
    0.33,
    0.33,
    0.33,
    0,
    0,
    0.33,
    0.33,
    0.33,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
];

class _ThumbnailEditorScreenState extends State<ThumbnailEditorScreen> {
  static const _outWidth = 1080.0;
  static const _outHeight = 1920.0;
  static const _stripHeight = 58.0;

  final _previewKey = GlobalKey<VideoPreviewWithOverlaysState>();

  var _failed = false;
  var _saving = false;
  var _filtersOpen = false;
  var _filterIndex = 0;
  var _scrub = 0.0;
  var _dragging = false;
  var _heroRequest = 0;
  Uint8List? _hero;
  List<Uint8List?> _frames = const [];
  List<int> _frameMs = const [];
  List<TextOverlay> _overlays = const [];
  String? _selectedOverlayId;
  String? _editingOverlayId;

  @override
  void initState() {
    super.initState();
    _loadFrames();
  }

  int get _scrubMs {
    final total = _timelineMaxMs;
    if (total <= 0) return 0;
    return (total * _scrub).round().clamp(0, total);
  }

  int _nearestFrame(int ms) {
    if (_frameMs.isEmpty) return 0;
    var best = 0;
    var bestDistance = 1 << 30;
    for (var i = 0; i < _frameMs.length; i++) {
      final distance = (_frameMs[i] - ms).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  Uint8List? get _selectedBytes {
    if (!_dragging && _hero != null) return _hero;
    final index = _nearestFrame(_scrubMs);
    if (index >= 0 && index < _frames.length) {
      final frame = _frames[index];
      if (frame != null) return frame;
    }
    return _hero;
  }

  Future<void> _loadHero() async {
    final request = ++_heroRequest;
    final timelineMs = _scrubMs;
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.project.sourcePath,
        imageFormat: ImageFormat.JPEG,
        timeMs: _sourceMs(timelineMs),
        maxHeight: 1280,
        maxWidth: 1280,
        quality: 86,
      );
      if (!mounted || request != _heroRequest) return;
      if (bytes == null || bytes.isEmpty) return;
      setState(() => _hero = bytes);
    } catch (error, stack) {
      debugPrint('[ThumbnailEditor] 미리보기 실패: $error\n$stack');
    }
  }

  Future<void> _loadFrames() async {
    final times = _frameTimes();
    final frames = List<Uint8List?>.filled(times.length, null);
    if (!mounted) return;
    setState(() => _frameMs = times);
    try {
      for (var i = 0; i < times.length; i++) {
        final bytes = await VideoThumbnail.thumbnailData(
          video: widget.project.sourcePath,
          imageFormat: ImageFormat.JPEG,
          timeMs: _sourceMs(times[i]),
          maxHeight: 360,
          maxWidth: 360,
          quality: 68,
        );
        if (!mounted) return;
        if (bytes == null || bytes.isEmpty) continue;
        frames[i] = bytes;
        setState(() => _frames = List<Uint8List?>.of(frames));
      }
    } catch (error, stack) {
      debugPrint('[ThumbnailEditor] 프레임 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _failed = true);
    }
    if (mounted) unawaited(_loadHero());
  }

  int get _stripFrameCount {
    final total = _timelineMaxMs;
    if (total <= 0) return 12;
    return (total / 400).ceil().clamp(12, 28);
  }

  List<int> _frameTimes() {
    final total = _timelineMaxMs;
    final count = _stripFrameCount;
    if (total <= 0) return const [0];
    if (count <= 1) return const [0];
    return [for (var i = 0; i < count; i++) (total * i / (count - 1)).round()];
  }

  int get _timelineMaxMs {
    final trimmed = widget.project.trimmedDuration.inMilliseconds;
    if (trimmed > 0) return trimmed;
    return 0;
  }

  int _sourceMs(int timelineMs) {
    final segments = widget.project.segments;
    if (segments.isEmpty) return timelineMs;
    var cursor = 0;
    for (final segment in segments) {
      final length = segment.duration.inMilliseconds;
      if (length <= 0) continue;
      if (timelineMs < cursor + length) {
        return segment.start.inMilliseconds + (timelineMs - cursor);
      }
      cursor += length;
    }
    return segments.last.end.inMilliseconds - 1;
  }

  void _addText() {
    final overlay = TextOverlay(
      text: '',
      start: Duration.zero,
      end: const Duration(days: 1),
    );
    setState(() {
      _overlays = [..._overlays, overlay];
      _selectedOverlayId = overlay.id;
      _editingOverlayId = null;
      _filtersOpen = false;
    });
  }

  TextOverlay? get _editingOverlay {
    final id = _editingOverlayId;
    if (id == null) return null;
    for (final overlay in _overlays) {
      if (overlay.id == id) return overlay;
    }
    return null;
  }

  void _patch(String id, TextOverlay Function(TextOverlay current) update) {
    setState(() {
      _overlays = [
        for (final overlay in _overlays)
          if (overlay.id == id) update(overlay) else overlay,
      ];
    });
  }

  void _applyToolbar(TextOverlay updated) {
    _patch(updated.id, (_) => fitOverlayBoxToText(updated));
  }

  Future<void> _confirm() async {
    if (_saving || _frameMs.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    try {
      final timelineMs = _scrubMs;
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.project.sourcePath,
        imageFormat: ImageFormat.JPEG,
        timeMs: _sourceMs(timelineMs),
        maxHeight: 1920,
        maxWidth: 1920,
        quality: 92,
      );
      if (bytes == null) throw StateError('thumbnail_empty');
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final file = await _compose(
        frame.image,
        _filters[_filterIndex].matrix,
        _overlays,
      );
      frame.image.dispose();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (error, stack) {
      debugPrint('[ThumbnailEditor] 저장 실패: $error\n$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.exportFailed)));
      setState(() => _saving = false);
    }
  }

  Future<File> _compose(
    ui.Image image,
    List<double>? matrix,
    List<TextOverlay> overlays,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final dest = const Rect.fromLTWH(0, 0, _outWidth, _outHeight);
    final paint = Paint();
    if (matrix != null) paint.colorFilter = ColorFilter.matrix(matrix);
    canvas.drawImageRect(image, _coverSource(image), dest, paint);
    for (final overlay in overlays) {
      _paintOverlay(canvas, overlay);
    }
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(
      _outWidth.round(),
      _outHeight.round(),
    );
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    picture.dispose();
    if (data == null) throw StateError('thumbnail_encode_failed');
    final file = File(
      '${Directory.systemTemp.path}/aveditor_thumb_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(data.buffer.asUint8List());
    return file;
  }

  Rect _coverSource(ui.Image image) {
    final imageAspect = image.width / image.height;
    const frameAspect = _outWidth / _outHeight;
    if (imageAspect > frameAspect) {
      final width = image.height * frameAspect;
      final left = (image.width - width) / 2;
      return Rect.fromLTWH(left, 0, width, image.height.toDouble());
    }
    final height = image.width / frameAspect;
    final top = (image.height - height) / 2;
    return Rect.fromLTWH(0, top, image.width.toDouble(), height);
  }

  void _paintOverlay(Canvas canvas, TextOverlay overlay) {
    final text = overlay.text.trim();
    if (text.isEmpty) return;
    final box = overlayBoxForFrame(overlay, frameWidth: _outWidth);
    final painter = TextPainter(
      text: TextSpan(
        text: overlay.text,
        style: overlayTextFillStyle(
          color: overlay.color,
          fontSize: box.fontSize,
          style: overlay.style,
          fontFamily: overlay.fontFamily,
        ),
      ),
      textAlign: overlay.textAlign,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: box.width);
    final center = Offset(
      _outWidth / 2 + overlay.offset.dx * _outWidth / 2,
      _outHeight / 2 + overlay.offset.dy * _outHeight / 2,
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(overlay.rotation);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final still = _selectedBytes;
    final ready = _frames.any((frame) => frame != null) && !_failed;

    final editingOverlay = _editingOverlay;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final frameHeight = width * 16 / 9;
          final frameWidth = frameHeight > height ? height * 9 / 16 : width;
          final fittedHeight = frameWidth * 16 / 9;
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: SizedBox(
                  width: frameWidth,
                  height: fittedHeight,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) =>
                        _previewKey.currentState?.handlePointerDown(event),
                    onPointerMove: (event) =>
                        _previewKey.currentState?.handlePointerMove(event),
                    onPointerUp: (event) => _previewKey.currentState
                        ?.handlePointerUp(event.pointer),
                    onPointerCancel: (event) => _previewKey.currentState
                        ?.handlePointerCancel(event.pointer),
                    child: ready
                        ? VideoPreviewWithOverlays(
                            key: _previewKey,
                            videoChild: still == null
                                ? const ColoredBox(color: Colors.black)
                                : _filteredStill(still),
                            videoAspectRatio: 9 / 16,
                            overlays: _overlays,
                            position: Duration.zero,
                            selectedOverlayId: _selectedOverlayId,
                            editingOverlayId: _editingOverlayId,
                            selectAllOnEdit: true,
                            textHint: l10n.textOverlayHint,
                            onOverlaySelected: (overlay) {
                              setState(() => _selectedOverlayId = overlay.id);
                            },
                            onRequestEdit: (overlay) {
                              setState(() {
                                _selectedOverlayId = overlay.id;
                                _editingOverlayId = overlay.id;
                              });
                            },
                            onEditingComplete: (_) {
                              setState(() => _editingOverlayId = null);
                            },
                            onBackgroundTap: () {
                              setState(() {
                                _selectedOverlayId = null;
                                _editingOverlayId = null;
                              });
                            },
                            onOverlayTextChanged: (overlay, text) {
                              _patch(
                                overlay.id,
                                (current) => current.copyWith(text: text),
                              );
                            },
                            onOverlayOffsetChanged: (overlay, offset) {
                              _patch(
                                overlay.id,
                                (current) => current.copyWith(offset: offset),
                              );
                            },
                            onOverlayBoxChanged: (overlay, transform) {
                              _patch(
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
                            onOverlayDeleted: (overlay) {
                              setState(() {
                                _overlays = [
                                  for (final item in _overlays)
                                    if (item.id != overlay.id) item,
                                ];
                                if (_selectedOverlayId == overlay.id) {
                                  _selectedOverlayId = null;
                                  _editingOverlayId = null;
                                }
                              });
                            },
                          )
                        : const ColoredBox(
                            color: Colors.black,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              SafeArea(
                child: Stack(
                  children: [
                    Positioned(
                      left: 12,
                      top: 8,
                      child: _roundButton(
                        icon: Icons.close,
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                      ),
                    ),
                    Positioned(
                      right: 12,
                      top: 8,
                      child: _roundButton(
                        icon: Icons.check,
                        filled: true,
                        onPressed: !ready || _saving ? null : _confirm,
                      ),
                    ),
                    if (editingOverlay == null)
                      Positioned(
                        right: 12,
                        top: height * 0.32,
                        child: Column(
                          children: [
                            _toolButton(
                              label: 'Aa',
                              onPressed: !ready || _saving ? null : _addText,
                            ),
                            const SizedBox(height: 12),
                            _toolButton(
                              icon: Icons.blur_on,
                              onPressed: !ready || _saving
                                  ? null
                                  : () => setState(
                                      () => _filtersOpen = !_filtersOpen,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    if (editingOverlay == null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_filtersOpen) _filterRow(),
                            const SizedBox(height: 10),
                            _filmstrip(),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (editingOverlay != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: BasicTextEditKeyboardTray(
                    overlay: editingOverlay,
                    onChanged: _applyToolbar,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _filteredStill(Uint8List bytes) {
    final image = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    final matrix = _filters[_filterIndex].matrix;
    if (matrix == null) return image;
    return ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: image);
  }

  Widget _filmstrip() {
    return SizedBox(
      height: _stripHeight,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final count = _frameMs.isEmpty ? 1 : _frameMs.length;
          final tileWidth = width / count;
          final windowWidth = (width * 0.18).clamp(46.0, 72.0);
          final travel = (width - windowWidth).clamp(0.0, width);
          final windowLeft = travel * _scrub.clamp(0.0, 1.0);

          void seekTo(double localX) {
            if (_saving || travel <= 0) return;
            final next = ((localX - windowWidth / 2) / travel).clamp(0.0, 1.0);
            setState(() {
              _dragging = true;
              _scrub = next;
            });
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => seekTo(details.localPosition.dx),
            onHorizontalDragStart: (details) =>
                seekTo(details.localPosition.dx),
            onHorizontalDragUpdate: (details) {
              if (_saving || travel <= 0) return;
              setState(() {
                _dragging = true;
                _scrub = (_scrub + details.delta.dx / travel).clamp(0.0, 1.0);
              });
            },
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              unawaited(_loadHero());
            },
            onTapUp: (_) {
              setState(() => _dragging = false);
              unawaited(_loadHero());
            },
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < count; i++)
                      SizedBox(
                        width: tileWidth,
                        height: _stripHeight,
                        child: i < _frames.length && _frames[i] != null
                            ? Image.memory(
                                _frames[i]!,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              )
                            : const ColoredBox(color: Color(0xFF2A2A2A)),
                      ),
                  ],
                ),
                Positioned(
                  left: windowLeft,
                  top: 0,
                  width: windowWidth,
                  height: _stripHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white, width: 2.5),
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

  Widget _filterRow() {
    const swatches = <Color>[
      Colors.white,
      Color(0xFFE7B089),
      Color(0xFF8FB4E8),
      Color(0xFFE25B5B),
      Color(0xFFBDBDBD),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final selected = index == _filterIndex;
          return GestureDetector(
            onTap: () => setState(() => _filterIndex = index),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: swatches[index],
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.white : Colors.black26,
                  width: selected ? 3 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool filled = false,
  }) {
    return Material(
      color: filled ? Colors.white : Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            color: filled ? Colors.black : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _toolButton({
    String? label,
    IconData? icon,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: label != null
                ? Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}
