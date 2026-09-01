import 'package:aveditor/config/music_api_config.dart';
import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/jamendo_music_service.dart';
import 'package:aveditor/services/music_storage_service.dart';
import 'package:aveditor/utils/duration_format.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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
  final _jamendo = const JamendoMusicService();
  final _storage = const MusicStorageService();

  List<RoyaltyFreeTrack> _tracks = [];
  bool _loading = false;
  String? _error;
  String? _busyTrackId;

  @override
  void initState() {
    super.initState();
    if (MusicApiConfig.hasJamendoCatalog) {
      _loadFeatured();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFeatured() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tracks = await _jamendo.featured();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
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
      final tracks = await _jamendo.search(query: query);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'search_failed';
      });
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

  Future<void> _selectTrack(RoyaltyFreeTrack track) async {
    final l10n = context.l10n;
    setState(() => _busyTrackId = track.id);
    try {
      final music = await _storage.importJamendoTrack(
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
    final hasCatalog = MusicApiConfig.hasJamendoCatalog;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.addMusic)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
          if (!hasCatalog)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.musicCatalogUnavailable,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: l10n.searchMusicHint,
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _loading ? null : _search,
                    icon: const Icon(Icons.arrow_forward),
                    tooltip: l10n.searchMusicHint,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.musicCatalogAttribution,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ],
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
          Expanded(child: _buildBody(l10n, hasCatalog)),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n, bool hasCatalog) {
    if (!hasCatalog) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.musicLocalOnlyHint,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _tracks.length,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final track = _tracks[index];
        final busy = _busyTrackId == track.id;
        return ListTile(
          leading: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.music_note_outlined),
          title: Text(track.title),
          subtitle: Text(
            '${track.artist} · ${formatDuration(track.duration)}',
          ),
          onTap: busy ? null : () => _selectTrack(track),
        );
      },
    );
  }
}
