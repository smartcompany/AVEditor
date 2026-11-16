import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

/// Custom multi-select gallery: tap media to preview/play; select via a
/// separate control so preview is never confused with picking.
class GalleryPickerScreen extends StatefulWidget {
  const GalleryPickerScreen({super.key});

  /// Opens the picker and returns selected library assets, or null if cancelled.
  static Future<List<AssetEntity>?> open(BuildContext context) {
    return Navigator.of(context).push<List<AssetEntity>>(
      MaterialPageRoute<List<AssetEntity>>(
        fullscreenDialog: true,
        builder: (_) => const GalleryPickerScreen(),
      ),
    );
  }

  @override
  State<GalleryPickerScreen> createState() => _GalleryPickerScreenState();
}

class _GalleryPickerScreenState extends State<GalleryPickerScreen> {
  static const _pageSize = 80;
  static const _thumbSize = ThumbnailSize.square(300);

  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];
  final Map<String, Uint8List?> _thumbCache = {};

  AssetPathEntity? _album;
  List<AssetPathEntity> _albums = const [];
  PermissionState _permission = PermissionState.notDetermined;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.readWrite,
        androidPermission: AndroidPermission(
          type: RequestType.common,
          mediaLocation: false,
        ),
      ),
    );
    if (!mounted) return;

    if (!permission.hasAccess) {
      setState(() {
        _permission = permission;
        _loading = false;
        _error = context.l10n.permissionPhotosDenied;
      });
      return;
    }

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      hasAll: true,
    );
    if (!mounted) return;

    final album = albums.isEmpty
        ? null
        : albums.firstWhere((a) => a.isAll, orElse: () => albums.first);

    setState(() {
      _permission = permission;
      _albums = albums;
      _album = album;
    });
    await _reloadAssets();
  }

  Future<void> _reloadAssets() async {
    final album = _album;
    if (album == null) {
      setState(() {
        _assets.clear();
        _loading = false;
        _hasMore = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
      _hasMore = true;
      _assets.clear();
    });

    try {
      final page = await album.getAssetListPaged(page: 0, size: _pageSize);
      if (!mounted) return;
      setState(() {
        _assets.addAll(page);
        _page = 1;
        _hasMore = page.length >= _pageSize;
        _loading = false;
      });
      unawaited(_prefetchThumbs(page));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await album.getAssetListPaged(page: _page, size: _pageSize);
      if (!mounted) return;
      setState(() {
        _assets.addAll(page);
        _page += 1;
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
      unawaited(_prefetchThumbs(page));
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _prefetchThumbs(List<AssetEntity> assets) async {
    var dirty = false;
    for (final asset in assets) {
      if (_thumbCache.containsKey(asset.id)) continue;
      final bytes = await asset.thumbnailDataWithSize(_thumbSize);
      if (!mounted) return;
      _thumbCache[asset.id] = bytes;
      dirty = true;
    }
    if (dirty && mounted) setState(() {});
  }

  Future<Uint8List?> _thumbFor(AssetEntity asset) async {
    final cached = _thumbCache[asset.id];
    if (cached != null || _thumbCache.containsKey(asset.id)) return cached;
    final bytes = await asset.thumbnailDataWithSize(_thumbSize);
    _thumbCache[asset.id] = bytes;
    return bytes;
  }

  int? _selectionIndex(AssetEntity asset) {
    final index = _selected.indexWhere((e) => e.id == asset.id);
    return index < 0 ? null : index + 1;
  }

  void _toggleSelect(AssetEntity asset) {
    setState(() {
      final index = _selected.indexWhere((e) => e.id == asset.id);
      if (index >= 0) {
        _selected.removeAt(index);
      } else {
        _selected.add(asset);
      }
    });
  }

  Future<void> _openPreview(AssetEntity asset) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _MediaPreviewScreen(
          asset: asset,
          initiallySelected: _selectionIndex(asset) != null,
        ),
      ),
    );
    if (!mounted || result == null) return;
    final selected = _selectionIndex(asset) != null;
    if (result != selected) {
      _toggleSelect(asset);
    }
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    Navigator.of(context).pop(List<AssetEntity>.from(_selected));
  }

  Future<void> _pickAlbum() async {
    if (_albums.length <= 1) return;
    final chosen = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      backgroundColor: AppTheme.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _albums.length,
            itemBuilder: (_, index) {
              final album = _albums[index];
              final selected = album.id == _album?.id;
              return ListTile(
                title: Text(
                  album.name,
                  style: GoogleFonts.dmSans(
                    color: AppTheme.ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                trailing: selected
                    ? const Icon(Icons.check, color: AppTheme.accentCyan)
                    : null,
                onTap: () => Navigator.pop(sheetContext, album),
              );
            },
          ),
        );
      },
    );
    if (chosen == null || chosen.id == _album?.id) return;
    setState(() => _album = chosen);
    await _reloadAssets();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: InkWell(
          onTap: _albums.length > 1 ? _pickAlbum : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _album?.name ?? l10n.galleryPickerTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_albums.length > 1) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 20),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (_permission.isLimited)
            TextButton(
              onPressed: () async {
                await PhotoManager.presentLimited(type: RequestType.common);
                await _bootstrap();
              },
              child: Text(l10n.galleryManageAccess),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _SelectionBar(
            count: _selected.length,
            onConfirm: _selected.isEmpty ? null : _confirm,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final l10n = context.l10n;
    if (_loading && _assets.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _assets.isEmpty) {
      return _PermissionOrError(
        message: _error!,
        onOpenSettings: () => PhotoManager.openSetting(),
        onRetry: _bootstrap,
      );
    }
    if (_assets.isEmpty) {
      return Center(
        child: Text(
          l10n.galleryPickerEmpty,
          style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 15),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.pixels >
            notification.metrics.maxScrollExtent - 600) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: _assets.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _assets.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final asset = _assets[index];
          return _GalleryTile(
            asset: asset,
            selectionIndex: _selectionIndex(asset),
            thumbFuture: _thumbFor(asset),
            onPreview: () => unawaited(_openPreview(asset)),
            onToggleSelect: () => _toggleSelect(asset),
          );
        },
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.asset,
    required this.selectionIndex,
    required this.thumbFuture,
    required this.onPreview,
    required this.onToggleSelect,
  });

  final AssetEntity asset;
  final int? selectionIndex;
  final Future<Uint8List?> thumbFuture;
  final VoidCallback onPreview;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final isVideo = asset.type == AssetType.video;
    final selected = selectionIndex != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        Material(
          color: AppTheme.surface,
          child: InkWell(
            onTap: onPreview,
            child: FutureBuilder<Uint8List?>(
              future: thumbFuture,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null) {
                  return const ColoredBox(
                    color: AppTheme.surfaceElevated,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                );
              },
            ),
          ),
        ),
        if (isVideo)
          Positioned(
            left: 6,
            bottom: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      formatDuration(Duration(seconds: asset.duration)),
                      style: GoogleFonts.dmSans(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          top: 4,
          right: 4,
          child: _SelectBadge(
            index: selectionIndex,
            selected: selected,
            onTap: onToggleSelect,
            semanticLabel: context.l10n.gallerySelectToggle,
          ),
        ),
      ],
    );
  }
}

class _SelectBadge extends StatelessWidget {
  const _SelectBadge({
    required this.index,
    required this.selected,
    required this.onTap,
    required this.semanticLabel,
  });

  final int? index;
  final bool selected;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Ink(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? AppTheme.accent
                  : Colors.black.withValues(alpha: 0.35),
              border: Border.all(
                color: selected ? AppTheme.accent : Colors.white70,
                width: 1.5,
              ),
            ),
            child: Center(
              child: selected
                  ? Text(
                      '${index ?? ''}',
                      style: GoogleFonts.dmSans(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.onConfirm});

  final int count;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border(
            top: BorderSide(color: AppTheme.accent.withValues(alpha: 0.18)),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  count == 0
                      ? l10n.galleryPickerHint
                      : l10n.gallerySelectedCount(count),
                  style: GoogleFonts.dmSans(
                    color: AppTheme.muted,
                    fontSize: 14,
                  ),
                ),
              ),
              FilledButton(
                onPressed: onConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.surfaceElevated,
                  disabledForegroundColor: AppTheme.muted,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  count == 0
                      ? l10n.galleryAddSelected
                      : l10n.galleryAddSelectedCount(count),
                  style: GoogleFonts.dmSans(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionOrError extends StatelessWidget {
  const _PermissionOrError({
    required this.message,
    required this.onOpenSettings,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(color: AppTheme.ink, fontSize: 15),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: onOpenSettings,
                  child: Text(l10n.openSettings),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(l10n.galleryRetry),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaPreviewScreen extends StatefulWidget {
  const _MediaPreviewScreen({
    required this.asset,
    required this.initiallySelected,
  });

  final AssetEntity asset;
  final bool initiallySelected;

  @override
  State<_MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<_MediaPreviewScreen> {
  VideoPlayerController? _controller;
  Uint8List? _imageBytes;
  bool _loading = true;
  String? _error;
  late bool _selected;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initiallySelected;
    unawaited(_load());
  }

  void _onVideoTick() {
    final playing = _controller?.value.isPlaying ?? false;
    if (playing != _playing && mounted) {
      setState(() => _playing = playing);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onVideoTick);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.asset.type == AssetType.video) {
        final file = await widget.asset.file;
        if (!mounted) return;
        if (file == null || !await file.exists()) {
          setState(() {
            _loading = false;
            _error = context.l10n.videoLoadError;
          });
          return;
        }
        final controller = VideoPlayerController.file(File(file.path));
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        await controller.setLooping(true);
        controller.addListener(_onVideoTick);
        setState(() {
          _controller = controller;
          _loading = false;
        });
        unawaited(controller.play());
      } else {
        final bytes =
            await widget.asset.originBytes ??
            await widget.asset.thumbnailDataWithSize(
              const ThumbnailSize(1600, 1600),
            );
        if (!mounted) return;
        if (bytes == null) {
          setState(() {
            _loading = false;
            _error = context.l10n.videoLoadError;
          });
          return;
        }
        setState(() {
          _imageBytes = bytes;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
    } else {
      unawaited(controller.play());
    }
    setState(() {});
  }

  void _pop() => Navigator.of(context).pop(_selected);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isVideo = widget.asset.type == AssetType.video;
    final controller = _controller;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _pop,
          ),
          title: Text(
            isVideo ? l10n.galleryVideoPreview : l10n.galleryPhotoPreview,
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  : isVideo && controller != null
                  ? GestureDetector(
                      onTap: _togglePlay,
                      behavior: HitTestBehavior.opaque,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio == 0
                                  ? 9 / 16
                                  : controller.value.aspectRatio,
                              child: VideoPlayer(controller),
                            ),
                          ),
                          if (!_playing)
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 24,
                            child: VideoProgressIndicator(
                              controller,
                              allowScrubbing: true,
                              colors: const VideoProgressColors(
                                playedColor: AppTheme.accent,
                                bufferedColor: Colors.white24,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: _imageBytes == null
                            ? const SizedBox.shrink()
                            : Image.memory(_imageBytes!, fit: BoxFit.contain),
                      ),
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _pop,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(l10n.galleryBackToGrid),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          setState(() => _selected = !_selected);
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: _selected
                              ? AppTheme.accentCyan
                              : AppTheme.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                          _selected ? l10n.galleryDeselect : l10n.gallerySelect,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
