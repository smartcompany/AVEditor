import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:flutter/foundation.dart';

/// One downloadable / bundled text template (CapCut-style pack item).
@immutable
class TextTemplatePackItem {
  const TextTemplatePackItem({
    required this.id,
    required this.title,
    required this.style,
    this.kind = 'effect',
    this.premium = false,
    this.lottieAsset,
    this.lottieUrl,
    this.previewUrl,
    this.downloadSizeBytes = 0,
    this.animation = TextEntranceAnimation.none,
  });

  final String id;
  final String title;
  final TextStyleTemplate style;

  /// `effect` (static look) or `template` (effect + motion).
  final String kind;
  final bool premium;

  /// Bundled Lottie path, e.g. `assets/text_packs/lottie/hearts.json`.
  final String? lottieAsset;

  /// Remote Lottie URL (relative to catalog [baseUrl] or absolute).
  final String? lottieUrl;
  final String? previewUrl;
  final int downloadSizeBytes;

  /// Default entrance animation when this pack is applied.
  final TextEntranceAnimation animation;

  bool get hasLottie =>
      (lottieAsset != null && lottieAsset!.isNotEmpty) ||
      (lottieUrl != null && lottieUrl!.isNotEmpty);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'premium': premium,
    'style': style.toJson(),
    if (lottieAsset != null) 'lottieAsset': lottieAsset,
    if (lottieUrl != null) 'lottieUrl': lottieUrl,
    if (previewUrl != null) 'previewUrl': previewUrl,
    'downloadSizeBytes': downloadSizeBytes,
    if (!animation.isNone) 'animation': animation.toJson(),
  };

  factory TextTemplatePackItem.fromJson(Map<String, dynamic> json) {
    final styleJson = Map<String, dynamic>.from(
      json['style'] as Map<String, dynamic>? ?? const {},
    );
    styleJson['id'] ??= json['id'];
    styleJson['label'] ??= json['title'] ?? json['id'];

    return TextTemplatePackItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      kind: json['kind'] as String? ?? 'effect',
      premium: json['premium'] as bool? ?? false,
      style: TextStyleTemplate.fromJson(styleJson),
      lottieAsset: json['lottieAsset'] as String?,
      lottieUrl: json['lottieUrl'] as String?,
      previewUrl: json['previewUrl'] as String?,
      downloadSizeBytes: json['downloadSizeBytes'] as int? ?? 0,
      animation: TextEntranceAnimation.fromJson(
        json['animation'] as Map<String, dynamic>?,
      ),
    );
  }
}

@immutable
class TextTemplatePackCategory {
  const TextTemplatePackCategory({
    required this.id,
    required this.title,
    required this.items,
  });

  final String id;
  final String title;
  final List<TextTemplatePackItem> items;

  factory TextTemplatePackCategory.fromJson(Map<String, dynamic> json) {
    return TextTemplatePackCategory(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => TextTemplatePackItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Root catalog for bundled or remote Word Art packs.
@immutable
class TextTemplatePackCatalog {
  const TextTemplatePackCatalog({
    required this.version,
    required this.categories,
    this.baseUrl = '',
  });

  final int version;
  final String baseUrl;
  final List<TextTemplatePackCategory> categories;

  List<TextTemplatePackItem> get allItems => [
    for (final category in categories) ...category.items,
  ];

  TextTemplatePackItem? itemById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final item in allItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  factory TextTemplatePackCatalog.fromJson(Map<String, dynamic> json) {
    return TextTemplatePackCatalog(
      version: json['version'] as int? ?? 1,
      baseUrl: json['baseUrl'] as String? ?? '',
      categories: (json['categories'] as List<dynamic>? ?? const [])
          .map(
            (e) => TextTemplatePackCategory.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  factory TextTemplatePackCatalog.empty() =>
      const TextTemplatePackCatalog(version: 0, categories: []);
}
