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

/// CapCut-style music / SFX browser: search → preview → download into the project.
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

class _MusicPickerScreenState extends State<MusicPickerScreen>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _catalog = MusicCatalogService();
  final _storage = MusicStorageService();
  final _previewPlayer = AudioPlayer();

  late final TabController _tabController;

  List<RoyaltyFreeTrack> _tracks = [];
  List<CatalogGenre> _genres = CatalogGenre.defaultsFor(CatalogAudioKind.music);
  List<MusicAutocompleteSuggestion> _suggestions = [];
  bool _loading = true;
  bool _catalogConfigured = true;
  bool _showSuggestions = false;
  String? _error;
  String? _busyTrackId;
  String? _previewTrackId;
  String? _attribution;
  String? _selectedGenreId;
  Timer? _debounce;
  Timer? _autocompleteDebounce;
  int _loadToken = 0;

  CatalogAudioKind get _kind =>
      _tabController.index == 1 ? CatalogAudioKind.sfx : CatalogAudioKind.music;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _searchController.addListener(_onSearchTextChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _autocompleteDebounce?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    unawaited(_previewPlayer.dispose());
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      _selectedGenreId = null;
      _suggestions = [];
      _showSuggestions = false;
      _genres = CatalogGenre.defaultsFor(_kind);
      _searchController.clear();
    });
    unawaited(_loadCatalog());
  }

  void _onSearchTextChanged() {
    _autocompleteDebounce?.cancel();
    final text = _searchController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    _autocompleteDebounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(_fetchAutocomplete(text));
    });
  }

  Future<void> _bootstrap() async {
    await TextTemplatePackService.instance.ensureInitialized();
    if (!mounted) return;
    await _loadCatalog();
  }

  Future<void> _fetchAutocomplete(String prefix) async {
    try {
      final suggestions = await _catalog.autocomplete(
        prefix: prefix,
        kind: _kind,
      );
      if (!mounted || _searchController.text.trim() != prefix) return;
      setState(() {
        _suggestions = suggestions;
        _showSuggestions = suggestions.isNotEmpty && _searchFocus.hasFocus;
      });
    } catch (_) {
      // Autocomplete is best-effort.
    }
  }

  Future<void> _loadCatalog({String? query, String? genreQuery}) async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
      _showSuggestions = false;
    });

    try {
      final page = await _catalog.search(
        query: query ?? '',
        genre: genreQuery,
        kind: _kind,
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        _catalogConfigured = page.configured;
        _tracks = page.tracks;
        if (page.genres.isNotEmpty) _genres = page.genres;
        _attribution = page.attribution;
        _loading = false;
        if (!page.configured) {
          _error = page.error;
        } else if (page.error != null && page.tracks.isEmpty) {
          _error = page.error;
        }
      });
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = 'load_failed';
      });
    }
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_runSearch());
    });
  }

  Future<void> _runSearch() async {
    final query = _searchController.text.trim();
    String? genreQuery;
    for (final g in _genres) {
      if (g.id == _selectedGenreId) {
        genreQuery = g.query;
        break;
      }
    }
    await _loadCatalog(query: query, genreQuery: genreQuery);
  }

  Future<void> _selectGenre(CatalogGenre? genre) async {
    setState(() {
      _selectedGenreId = genre?.id;
      if (genre != null) {
        // Keep the chip as the filter; clear free-text so results match the mood.
        _searchController.value = TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );
      }
    });
    await _loadCatalog(genreQuery: genre?.query);
  }

  Future<void> _applySuggestion(String text) async {
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _showSuggestions = false;
      _selectedGenreId = null;
    });
    _searchFocus.unfocus();
    await _loadCatalog(query: text);
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

  String _genreLabel(AppLocalizations l10n, CatalogGenre genre) {
    switch (genre.id) {
      case 'travel':
        return l10n.musicGenreTravel;
      case 'beauty':
        return l10n.musicGenreBeauty;
      case 'fashion':
        return l10n.musicGenreFashion;
      case 'happy':
        return l10n.musicGenreHappy;
      case 'energetic':
        return l10n.musicGenreEnergetic;
      case 'chill':
        return l10n.musicGenreChill;
      case 'cinematic':
        return l10n.musicGenreCinematic;
      case 'romantic':
        return l10n.musicGenreRomantic;
      case 'sports':
        return l10n.musicGenreSports;
      case 'nature':
        return l10n.musicGenreNature;
      case 'cooking':
        return l10n.musicGenreCooking;
      case 'corporate':
        return l10n.musicGenreCorporate;
      case 'hip-hop':
        return l10n.musicGenreHipHop;
      case 'pop':
        return l10n.musicGenrePop;
      case 'children':
        return l10n.musicGenreKids;
      case 'whoosh':
        return l10n.sfxGenreWhoosh;
      case 'transition':
        return l10n.sfxGenreTransition;
      case 'impact':
        return l10n.sfxGenreImpact;
      case 'glitch':
        return l10n.sfxGenreGlitch;
      case 'notification':
        return l10n.sfxGenreNotification;
      case 'game':
        return l10n.sfxGenreGame;
      case 'technology':
        return l10n.sfxGenreTech;
      case 'ui':
        return l10n.sfxGenreUi;
      default:
        return genre.label;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isSfx = _kind == CatalogAudioKind.sfx;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addMusic),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.musicTabMusic),
            Tab(text: l10n.musicTabSfx),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  enabled: _catalogConfigured || _loading,
                  decoration: InputDecoration(
                    hintText: isSfx
                        ? l10n.searchSfxHint
                        : l10n.searchMusicHint,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _suggestions = [];
                                _showSuggestions = false;
                              });
                              unawaited(_runSearch());
                            },
                            icon: const Icon(Icons.clear),
                          ),
                        IconButton(
                          onPressed: _loading
                              ? null
                              : () {
                                  setState(() => _showSuggestions = false);
                                  unawaited(_runSearch());
                                },
                          icon: const Icon(Icons.arrow_forward),
                        ),
                      ],
                    ),
                    filled: true,
                    fillColor: AppTheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  textInputAction: TextInputAction.search,
                  onTap: () {
                    if (_suggestions.isNotEmpty) {
                      setState(() => _showSuggestions = true);
                    }
                  },
                  onChanged: (_) {
                    setState(() {}); // refresh clear button
                    _scheduleSearch();
                  },
                  onSubmitted: (_) {
                    setState(() => _showSuggestions = false);
                    unawaited(_runSearch());
                  },
                ),
                if (_showSuggestions && _suggestions.isNotEmpty)
                  Material(
                    color: AppTheme.surface,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(12),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _suggestions.length,
                        itemBuilder: (context, index) {
                          final s = _suggestions[index];
                          final icon = s.kind == 'genre'
                              ? Icons.category_outlined
                              : s.kind == 'tag'
                                  ? Icons.tag
                                  : Icons.music_note_outlined;
                          return ListTile(
                            dense: true,
                            leading: Icon(icon, size: 20),
                            title: Text(s.text),
                            onTap: () => unawaited(_applySuggestion(s.text)),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: Text(l10n.musicGenreAll),
                    selected: _selectedGenreId == null,
                    onSelected: (_) => unawaited(_selectGenre(null)),
                  ),
                ),
                for (final genre in _genres)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(_genreLabel(l10n, genre)),
                      selected: _selectedGenreId == genre.id,
                      onSelected: (_) => unawaited(
                        _selectGenre(
                          _selectedGenreId == genre.id ? null : genre,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
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
                  avatar: Icon(
                    isSfx ? Icons.graphic_eq : Icons.music_note,
                    size: 18,
                  ),
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

    if (_error != null && _tracks.isEmpty) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(_runSearch()),
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
          isSfx: _kind == CatalogAudioKind.sfx,
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
    required this.isSfx,
    required this.onPreview,
    required this.onUse,
    required this.useLabel,
  });

  final RoyaltyFreeTrack track;
  final bool busy;
  final bool previewing;
  final bool isSfx;
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
            _Cover(
              imageUrl: track.imageUrl,
              previewing: previewing,
              isSfx: isSfx,
            ),
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
                previewing
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
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
  const _Cover({
    required this.imageUrl,
    required this.previewing,
    required this.isSfx,
  });

  final String imageUrl;
  final bool previewing;
  final bool isSfx;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: const Color(0xFF1C1F28),
      child: Icon(
        isSfx ? Icons.graphic_eq : Icons.music_note,
        color: Colors.white54,
      ),
    );

    final child = imageUrl.isEmpty
        ? placeholder
        : Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stackTrace) => placeholder,
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
