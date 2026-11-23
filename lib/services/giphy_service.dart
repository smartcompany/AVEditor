import 'dart:convert';

import 'package:aveditor/config/giphy_config.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Giphy Stickers API. Key lives in [GiphyConfig].
class GiphyService {
  GiphyService({http.Client? client}) : _client = client ?? http.Client();

  static String get apiKey => GiphyConfig.apiKey;

  static bool get hasApiKey => apiKey.trim().isNotEmpty;

  final http.Client _client;

  Future<List<GiphySticker>> trending({int limit = 40, int offset = 0}) {
    return _fetch(
      path: '/v1/stickers/trending',
      query: {'limit': '$limit', 'offset': '$offset', 'rating': 'pg-13'},
    );
  }

  Future<List<GiphySticker>> search(
    String query, {
    int limit = 40,
    int offset = 0,
  }) {
    final q = query.trim();
    if (q.isEmpty) return trending(limit: limit, offset: offset);
    return _fetch(
      path: '/v1/stickers/search',
      query: {
        'q': q,
        'limit': '$limit',
        'offset': '$offset',
        'rating': 'pg-13',
        'lang': 'en',
      },
    );
  }

  Future<List<GiphySticker>> _fetch({
    required String path,
    required Map<String, String> query,
  }) async {
    if (!hasApiKey) {
      throw StateError('giphy_api_key_missing');
    }
    final uri = Uri.https('api.giphy.com', path, {
      'api_key': apiKey,
      ...query,
    });
    final res = await _client.get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('[Giphy] ${res.statusCode} ${res.body}');
      throw StateError('giphy_http_${res.statusCode}');
    }
    final map = jsonDecode(utf8.decode(res.bodyBytes));
    if (map is! Map) return const [];
    final data = map['data'];
    if (data is! List) return const [];
    final out = <GiphySticker>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final sticker = GiphySticker.fromJson(Map<String, dynamic>.from(raw));
      if (sticker != null) out.add(sticker);
    }
    return out;
  }
}

@immutable
class GiphySticker {
  const GiphySticker({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.downloadUrl,
    required this.width,
    required this.height,
  });

  final String id;
  final String title;
  final String previewUrl;
  final String downloadUrl;
  final int width;
  final int height;

  static GiphySticker? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final images = json['images'];
    if (images is! Map) return null;
    final map = Map<String, dynamic>.from(images);
    final fixed = map['fixed_width'] ?? map['fixed_width_downsampled'];
    final original = map['original'] ?? fixed;
    String? urlOf(dynamic node) {
      if (node is! Map) return null;
      final u = node['url'] as String?;
      return (u != null && u.isNotEmpty) ? u : null;
    }

    final preview = urlOf(fixed) ?? urlOf(original);
    final download = urlOf(original) ?? preview;
    if (preview == null || download == null) return null;

    int dim(dynamic node, String key, int fallback) {
      if (node is! Map) return fallback;
      final v = node[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    final sizeNode = original is Map ? original : fixed;
    return GiphySticker(
      id: id,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : 'Sticker',
      previewUrl: preview,
      downloadUrl: download,
      width: dim(sizeNode, 'width', 200),
      height: dim(sizeNode, 'height', 200),
    );
  }
}
