import 'dart:convert';

import 'package:aveditor/config/music_api_config.dart';
import 'package:aveditor/models/royalty_free_track.dart';
import 'package:http/http.dart' as http;

/// Searches Jamendo's Creative Commons catalog.
///
/// Jamendo is free for non-commercial apps with attribution; commercial use
/// needs a separate license from Jamendo.
class JamendoMusicService {
  const JamendoMusicService({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const _baseUrl = 'https://api.jamendo.com/v3.0';

  bool get isConfigured => MusicApiConfig.hasJamendoCatalog;

  Future<List<RoyaltyFreeTrack>> search({
    required String query,
    int limit = 20,
    int offset = 0,
  }) async {
    if (!isConfigured) {
      throw StateError('jamendo_not_configured');
    }

    final uri = Uri.parse('$_baseUrl/tracks/').replace(
      queryParameters: {
        'client_id': MusicApiConfig.jamendoClientId,
        'format': 'json',
        'limit': '$limit',
        'offset': '$offset',
        'namesearch': query,
        'vocalinstrumental': 'instrumental',
        'audioformat': 'mp32',
        'include': 'musicinfo',
      },
    );

    final response = await (_client ?? http.Client()).get(uri);
    if (response.statusCode != 200) {
      throw StateError('jamendo_search_failed:${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? const [];
    return results
        .map((entry) => _parseTrack(entry as Map<String, dynamic>))
        .where((track) => track.downloadAllowed)
        .toList(growable: false);
  }

  Future<List<RoyaltyFreeTrack>> featured({int limit = 12}) async {
    if (!isConfigured) {
      throw StateError('jamendo_not_configured');
    }

    final uri = Uri.parse('$_baseUrl/tracks/').replace(
      queryParameters: {
        'client_id': MusicApiConfig.jamendoClientId,
        'format': 'json',
        'limit': '$limit',
        'order': 'popularity_total_desc',
        'vocalinstrumental': 'instrumental',
        'audioformat': 'mp32',
        'include': 'musicinfo',
      },
    );

    final response = await (_client ?? http.Client()).get(uri);
    if (response.statusCode != 200) {
      throw StateError('jamendo_search_failed:${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? const [];
    return results
        .map((entry) => _parseTrack(entry as Map<String, dynamic>))
        .where((track) => track.downloadAllowed)
        .toList(growable: false);
  }

  Uri downloadUri(String trackId) {
    return Uri.parse('$_baseUrl/tracks/file').replace(
      queryParameters: {
        'client_id': MusicApiConfig.jamendoClientId,
        'id': trackId,
        'action': 'download',
        'audioformat': 'mp32',
      },
    );
  }

  RoyaltyFreeTrack _parseTrack(Map<String, dynamic> json) {
    final durationSec = (json['duration'] as num?)?.toInt() ?? 0;
    return RoyaltyFreeTrack(
      id: '${json['id']}',
      title: json['name'] as String? ?? 'Untitled',
      artist: json['artist_name'] as String? ?? 'Unknown artist',
      duration: Duration(seconds: durationSec),
      previewUrl: json['audio'] as String? ?? '',
      downloadAllowed: json['audiodownload_allowed'] as bool? ?? false,
      licenseUrl: json['license_ccurl'] as String?,
    );
  }
}
