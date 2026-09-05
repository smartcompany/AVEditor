import 'dart:convert';

import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:http/http.dart' as http;

/// CapCut-style music / SFX catalog via the AVEditor server.
class MusicCatalogService {
  MusicCatalogService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String get _serverBase {
    final fromPacks = TextTemplatePackService.instance.remoteBaseUrl.trim();
    if (fromPacks.isNotEmpty) return fromPacks;
    return TextTemplatePackService.defaultRemoteBaseUrl;
  }

  String get _root {
    final base = _serverBase;
    return base.endsWith('/') ? base : '$base/';
  }

  /// Whether the remote catalog responded successfully.
  Future<bool> isCatalogAvailable() async {
    try {
      final result = await featured(limit: 1);
      return result.configured && result.tracks.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<MusicCatalogPage> featured({
    int limit = 24,
    CatalogAudioKind kind = CatalogAudioKind.music,
  }) {
    return _serverSearch(query: '', limit: limit, kind: kind);
  }

  Future<MusicCatalogPage> search({
    required String query,
    String? genre,
    int limit = 20,
    int offset = 0,
    CatalogAudioKind kind = CatalogAudioKind.music,
  }) {
    final q = query.trim();
    final g = genre?.trim() ?? '';
    if (q.isEmpty && g.isEmpty) return featured(limit: limit, kind: kind);
    return _serverSearch(
      query: q,
      genre: g,
      limit: limit,
      offset: offset,
      kind: kind,
    );
  }

  Future<List<MusicAutocompleteSuggestion>> autocomplete({
    required String prefix,
    CatalogAudioKind kind = CatalogAudioKind.music,
    int limit = 10,
  }) async {
    final q = prefix.trim();
    if (q.isEmpty) return const [];

    final uri = Uri.parse('${_root}api/music/autocomplete').replace(
      queryParameters: {
        'q': q,
        'kind': kind.apiValue,
        'limit': '$limit',
      },
    );

    final response = await _client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }

    final body = jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, dynamic>;
    final list = body['suggestions'] as List<dynamic>? ?? const [];
    return list
        .map((e) {
          final m = e as Map<String, dynamic>;
          return MusicAutocompleteSuggestion(
            text: m['text'] as String? ?? '',
            kind: m['kind'] as String? ?? 'tag',
          );
        })
        .where((s) => s.text.isNotEmpty)
        .toList(growable: false);
  }

  Uri downloadUriFor(RoyaltyFreeTrack track) {
    if (track.downloadUrl != null && track.downloadUrl!.isNotEmpty) {
      return Uri.parse(track.downloadUrl!);
    }
    return Uri.parse('${_root}api/music/file').replace(
      queryParameters: {'id': track.id},
    );
  }

  Future<MusicCatalogPage> _serverSearch({
    required String query,
    String genre = '',
    int limit = 20,
    int offset = 0,
    CatalogAudioKind kind = CatalogAudioKind.music,
  }) async {
    final uri = Uri.parse('${_root}api/music/search').replace(
      queryParameters: {
        if (query.isNotEmpty) 'q': query,
        if (genre.isNotEmpty) 'genre': genre,
        'kind': kind.apiValue,
        'limit': '$limit',
        'offset': '$offset',
      },
    );

    final response = await _client.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, dynamic>;

    if (response.statusCode == 503) {
      return MusicCatalogPage(
        configured: false,
        tracks: const [],
        genres: const [],
        attribution: body['attribution'] as String?,
        error: body['error'] as String?,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('music_search_failed:${response.statusCode}');
    }

    final genres = (body['genres'] as List<dynamic>? ?? const [])
        .map((e) {
          final m = e as Map<String, dynamic>;
          return CatalogGenre(
            id: m['id'] as String? ?? '',
            query: m['query'] as String? ?? '',
            label: m['label'] as String? ?? '',
          );
        })
        .where((g) => g.id.isNotEmpty && g.query.isNotEmpty)
        .toList(growable: false);

    final tracks = (body['tracks'] as List<dynamic>? ?? const [])
        .map((e) => RoyaltyFreeTrack.fromJson(e as Map<String, dynamic>))
        .map(
          (t) => RoyaltyFreeTrack(
            id: t.id,
            title: t.title,
            artist: t.artist,
            duration: t.duration,
            previewUrl: t.previewUrl,
            imageUrl: t.imageUrl,
            downloadAllowed: t.downloadAllowed,
            licenseUrl: t.licenseUrl,
            downloadUrl: t.downloadUrl ??
                Uri.parse('${_root}api/music/file')
                    .replace(queryParameters: {'id': t.id})
                    .toString(),
            source: t.source,
          ),
        )
        .where((t) => t.downloadAllowed)
        .toList(growable: false);

    return MusicCatalogPage(
      configured: body['configured'] as bool? ?? true,
      tracks: tracks,
      genres: genres.isNotEmpty ? genres : CatalogGenre.defaultsFor(kind),
      attribution: body['attribution'] as String?,
      error: body['error'] as String?,
    );
  }
}

enum CatalogAudioKind {
  music,
  sfx;

  String get apiValue => this == CatalogAudioKind.sfx ? 'sfx' : 'music';
}

class CatalogGenre {
  const CatalogGenre({
    required this.id,
    required this.query,
    required this.label,
  });

  final String id;
  final String query;
  final String label;

  static List<CatalogGenre> defaultsFor(CatalogAudioKind kind) {
    if (kind == CatalogAudioKind.sfx) {
      return const [
        CatalogGenre(id: 'whoosh', query: 'whoosh', label: 'Whoosh'),
        CatalogGenre(id: 'transition', query: 'transition', label: 'Transition'),
        CatalogGenre(id: 'impact', query: 'impact', label: 'Impact'),
        CatalogGenre(id: 'nature', query: 'nature', label: 'Nature'),
        CatalogGenre(id: 'cinematic', query: 'cinematic', label: 'Cinematic'),
        CatalogGenre(id: 'glitch', query: 'glitch', label: 'Glitch'),
        CatalogGenre(
          id: 'notification',
          query: 'notification',
          label: 'Notification',
        ),
        CatalogGenre(id: 'game', query: 'game', label: 'Game'),
        CatalogGenre(id: 'technology', query: 'technology', label: 'Tech'),
        CatalogGenre(id: 'ui', query: 'interface', label: 'UI'),
      ];
    }
    return const [
      CatalogGenre(id: 'travel', query: 'travel', label: 'Travel'),
      CatalogGenre(id: 'beauty', query: 'beauty', label: 'Beauty'),
      CatalogGenre(id: 'fashion', query: 'fashion', label: 'Fashion'),
      CatalogGenre(id: 'happy', query: 'happy', label: 'Happy'),
      CatalogGenre(id: 'energetic', query: 'energetic', label: 'Energetic'),
      CatalogGenre(id: 'chill', query: 'chillout', label: 'Chill'),
      CatalogGenre(id: 'cinematic', query: 'cinematic', label: 'Cinematic'),
      CatalogGenre(id: 'romantic', query: 'romantic', label: 'Romantic'),
      CatalogGenre(id: 'sports', query: 'sports', label: 'Sports'),
      CatalogGenre(id: 'nature', query: 'nature', label: 'Nature'),
      CatalogGenre(id: 'cooking', query: 'cooking', label: 'Cooking'),
      CatalogGenre(id: 'corporate', query: 'corporate', label: 'Corporate'),
      CatalogGenre(id: 'hip-hop', query: 'hip-hop', label: 'Hip Hop'),
      CatalogGenre(id: 'pop', query: 'pop', label: 'Pop'),
      CatalogGenre(id: 'children', query: 'children', label: 'Kids'),
    ];
  }
}

class MusicAutocompleteSuggestion {
  const MusicAutocompleteSuggestion({
    required this.text,
    required this.kind,
  });

  final String text;
  final String kind;
}

class MusicCatalogPage {
  const MusicCatalogPage({
    required this.configured,
    required this.tracks,
    this.genres = const [],
    this.attribution,
    this.error,
  });

  final bool configured;
  final List<RoyaltyFreeTrack> tracks;
  final List<CatalogGenre> genres;
  final String? attribution;
  final String? error;
}
