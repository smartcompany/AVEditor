import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum ShareTargetKind { youtube, instagram, facebook, whatsapp }

class ShareTarget {
  const ShareTarget({required this.kind, required this.labels});

  final ShareTargetKind kind;
  final Map<String, String> labels;

  String labelFor(String languageCode, String fallback) {
    final localized = labels[languageCode];
    if (localized != null && localized.isNotEmpty) return localized;
    final english = labels['en'];
    if (english != null && english.isNotEmpty) return english;
    return fallback;
  }
}

/// Ordered share destinations. The first item is the large button.
class ShareCatalogService {
  ShareCatalogService({http.Client? client})
    : _client = client ?? http.Client();

  static const catalogUrl =
      'https://aveditorserver.vercel.app/share/catalog.json';

  final http.Client _client;

  Future<List<ShareTarget>> load() async {
    try {
      final response = await _client
          .get(Uri.parse(catalogUrl))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final targets = _parse(response.body);
        if (targets.isNotEmpty) {
          debugPrint('[ExportShare] 공유 목록 ${targets.length}개 (서버)');
          return targets;
        }
      } else {
        debugPrint('[ExportShare] 공유 목록 응답 ${response.statusCode}');
      }
    } catch (error, stack) {
      debugPrint('[ExportShare] 공유 목록 실패: $error\n$stack');
    }
    debugPrint('[ExportShare] 공유 목록 기본값 사용');
    return fallback;
  }

  static const fallback = <ShareTarget>[
    ShareTarget(
      kind: ShareTargetKind.youtube,
      labels: {
        'ko': 'YouTube에 공유',
        'en': 'Share to YouTube',
        'ja': 'YouTubeにシェア',
        'zh': '分享到 YouTube',
      },
    ),
    ShareTarget(kind: ShareTargetKind.instagram, labels: {'en': 'Instagram'}),
    ShareTarget(kind: ShareTargetKind.whatsapp, labels: {'en': 'WhatsApp'}),
    ShareTarget(kind: ShareTargetKind.facebook, labels: {'en': 'Facebook'}),
  ];

  List<ShareTarget> _parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final raw = decoded['targets'];
    if (raw is! List) return const [];
    final targets = <ShareTarget>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final kind = _kind(item['kind']);
      if (kind == null) continue;
      if (targets.any((target) => target.kind == kind)) continue;
      targets.add(ShareTarget(kind: kind, labels: _labels(item['label'])));
    }
    return targets;
  }

  ShareTargetKind? _kind(Object? value) {
    return switch (value) {
      'youtube' => ShareTargetKind.youtube,
      'instagram' => ShareTargetKind.instagram,
      'facebook' => ShareTargetKind.facebook,
      'whatsapp' => ShareTargetKind.whatsapp,
      _ => null,
    };
  }

  Map<String, String> _labels(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }
}
