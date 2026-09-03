import 'dart:convert';

import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:http/http.dart' as http;

/// CapCut-style music catalog: search + featured lists via the AVEditor server.
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

  Future<MusicCatalogPage> featured({int limit = 24}) {
    return _serverSearch(query: '', limit: limit);
  }

  Future<MusicCatalogPage> search({
    required String query,
    int limit = 20,
    int offset = 0,
  }) {
    final q = query.trim();
    if (q.isEmpty) return featured(limit: limit);
    return _serverSearch(query: q, limit: limit, offset: offset);
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
    int limit = 20,
    int offset = 0,
  }) async {
    final uri = Uri.parse('${_root}api/music/search').replace(
      queryParameters: {
        if (query.isNotEmpty) 'q': query,
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
        attribution: body['attribution'] as String?,
        error: body['error'] as String?,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('music_search_failed:${response.statusCode}');
    }

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
      attribution: body['attribution'] as String?,
      error: body['error'] as String?,
    );
  }
}

class MusicCatalogPage {
  const MusicCatalogPage({
    required this.configured,
    required this.tracks,
    this.attribution,
    this.error,
  });

  final bool configured;
  final List<RoyaltyFreeTrack> tracks;
  final String? attribution;
  final String? error;
}
