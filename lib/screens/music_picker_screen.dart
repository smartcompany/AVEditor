import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/music_catalog_service.dart';
import 'package:aveditor/services/music_storage_service.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// CapCut-style music browser: search → preview → download into the project.
class MusicPickerScreen extends StatefulWidget {
  const MusicPickerScreen({
    super.key,
    required this.projectDir,
    this.current,
  });

  final String projectDir;
  final ProjectMusic? current;

  @override
  State<MusicPickerScreen> createState() => _MusicPickerScreenState();
}

class _MusicPickerScreenState extends State<MusicPickerScreen> {
  final _searchController = TextEditingController();
  final _catalog = MusicCatalogService();
  final _storage = MusicStorageService();
  final _previewPlayer = AudioPlayer();

  List<RoyaltyFreeTrack> _tracks = [];
  bool _loading = true;
  bool _catalogConfigured = true;
  String? _error;
  String? _busyTrackId;
  String? _previewTrackId;
  String? _attribution;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _searchController.dispose();
    unawaited(_previewPlayer.dispose());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await TextTemplatePackService.instance.ensureInitialized();
    if (!mounted) return;
    await _loadFeatured();
  }

  Future<void> _loadFeatured() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _catalog.featured();
      if (!mounted) return;
      setState(() {
        _catalogConfigured = page.configured;
        _tracks = page.tracks;
        _attribution = page.attribution;
        _loading = false;
        if (!page.configured) {
          _error = page.error;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'featured_load_failed';
      });
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      await _loadFeatured();
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _catalog.search(query: query);
      if (!mounted) return;
      setState(() {
        _catalogConfigured = page.configured;
        _tracks = page.tracks;
        _attribution = page.attribution;
        _loading = false;
        if (!page.configured) {
          _error = page.error;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'search_failed';
      });
    }
  }

  Future<void> _togglePreview(RoyaltyFreeTrack track) async {
    if (track.previewUrl.isEmpty) return;

    if (_previewTrackId == track.id) {
      await _previewPlayer.stop();
      if (!mounted) return;
      setState(() => _previewTrackId = null);
      return;
    }

    setState(() => _previewTrackId = track.id);
    try {
      await _previewPlayer.stop();
      await _previewPlayer.play(UrlSource(track.previewUrl));
    } catch (_) {
      if (!mounted) return;
      setState(() => _previewTrackId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.musicPreviewFailed)),
      );
    }
  }

  Future<void> _pickLocalFile() async {
    final l10n = context.l10n;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'audio',
          extensions: ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac'],
        ),
      ],
    );
    if (picked == null || !mounted) return;

    setState(() => _busyTrackId = 'local');
    try {
      await _previewPlayer.stop();
      final music = await _storage.importLocalFile(
        projectDir: widget.projectDir,
        pickedPath: picked.path,
        title: p.basenameWithoutExtension(picked.name),
      );
      if (!mounted) return;
      Navigator.of(context).pop(music);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.musicImportFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _busyTrackId = null);
    }
  }

  Future<void> _downloadTrack(RoyaltyFreeTrack track) async {
    final l10n = context.l10n;
    setState(() => _busyTrackId = track.id);
    try {
      await _previewPlayer.stop();
      setState(() => _previewTrackId = null);
      final music = await _storage.importCatalogTrack(
        projectDir: widget.projectDir,
        track: track,
      );
      if (!mounted) return;
      Navigator.of(context).pop(music);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.musicImportFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _busyTrackId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.addMusic)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              enabled: _catalogConfigured || _loading,
              decoration: InputDecoration(
                hintText: l10n.searchMusicHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  onPressed: _loading ? null : _search,
                  icon: const Icon(Icons.arrow_forward),
                ),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busyTrackId == null ? _pickLocalFile : null,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(l10n.importMusicFile),
                  ),
                ),
              ],
            ),
          ),
          if (_attribution != null || _catalogConfigured)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _attribution ?? l10n.musicCatalogAttribution,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          if (widget.current != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  avatar: const Icon(Icons.music_note, size: 18),
                  label: Text(widget.current!.title),
                ),
              ),
            ),
          Expanded(child: _buildBody(l10n)),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_catalogConfigured) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.musicCatalogUnavailable,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.musicLocalOnlyHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _pickLocalFile,
                child: Text(l10n.importMusicFile),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: TextButton(
          onPressed: _loadFeatured,
          child: Text(l10n.retry),
        ),
      );
    }

    if (_tracks.isEmpty) {
      return Center(child: Text(l10n.musicNoResults));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: _tracks.length,
      separatorBuilder: (_, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final track = _tracks[index];
        final busy = _busyTrackId == track.id;
        final previewing = _previewTrackId == track.id;
        return _TrackTile(
          track: track,
          busy: busy,
          previewing: previewing,
          onPreview: () => _togglePreview(track),
          onUse: busy ? null : () => _downloadTrack(track),
          useLabel: l10n.useMusicTrack,
        );
      },
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.busy,
    required this.previewing,
    required this.onPreview,
    required this.onUse,
    required this.useLabel,
  });

  final RoyaltyFreeTrack track;
  final bool busy;
  final bool previewing;
  final VoidCallback onPreview;
  final VoidCallback? onUse;
  final String useLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
        child: Row(
          children: [
            _Cover(imageUrl: track.imageUrl, previewing: previewing),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${track.artist} · ${formatDuration(track.duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: track.previewUrl.isEmpty ? null : onPreview,
              icon: Icon(
                previewing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              ),
              tooltip: previewing ? 'Stop' : 'Preview',
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton(
                onPressed: onUse,
                child: Text(useLabel),
              ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.imageUrl, required this.previewing});

  final String imageUrl;
  final bool previewing;

  @override
  Widget build(BuildContext context) {
    final child = imageUrl.isEmpty
        ? const ColoredBox(
            color: Color(0xFF1C1F28),
            child: Icon(Icons.music_note, color: Colors.white54),
          )
        : Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stackTrace) => const ColoredBox(
              color: Color(0xFF1C1F28),
              child: Icon(Icons.music_note, color: Colors.white54),
            ),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 52,
        height: 52,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (previewing)
              const ColoredBox(
                color: Color(0x66000000),
                child: Icon(Icons.equalizer, color: Colors.white, size: 22),
              ),
          ],
        ),
      ),
    );
  }
}
