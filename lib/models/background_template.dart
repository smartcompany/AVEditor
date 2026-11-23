import 'package:flutter/foundation.dart';

/// One server-driven still background for prologue / epilogue clips.
@immutable
class BackgroundTemplate {
  const BackgroundTemplate({
    required this.id,
    required this.title,
    required this.imageUrl,
    this.previewUrl,
    this.defaultDurationMs = 5000,
  });

  final String id;
  final String title;
  final String imageUrl;
  final String? previewUrl;
  final int defaultDurationMs;

  Duration get defaultDuration =>
      Duration(milliseconds: defaultDurationMs.clamp(500, 300000));

  String get previewOrImage =>
      (previewUrl != null && previewUrl!.isNotEmpty) ? previewUrl! : imageUrl;

  factory BackgroundTemplate.fromJson(Map<String, dynamic> json) {
    return BackgroundTemplate(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      imageUrl: json['imageUrl'] as String? ?? '',
      previewUrl: json['previewUrl'] as String?,
      defaultDurationMs: (json['defaultDurationMs'] as num?)?.toInt() ?? 5000,
    );
  }
}

@immutable
class BackgroundCatalog {
  const BackgroundCatalog({
    required this.version,
    required this.items,
    this.baseUrl = '',
  });

  final int version;
  final String baseUrl;
  final List<BackgroundTemplate> items;

  static const empty = BackgroundCatalog(version: 0, items: []);

  factory BackgroundCatalog.fromJson(Map<String, dynamic> json) {
    return BackgroundCatalog(
      version: (json['version'] as num?)?.toInt() ?? 0,
      baseUrl: json['baseUrl'] as String? ?? '',
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => BackgroundTemplate.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  String resolveUrl(String relativeOrAbsolute) {
    final value = relativeOrAbsolute.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('asset:')) {
      return value;
    }
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return '$base${value.replaceFirst(RegExp(r'^/'), '')}';
  }
}
