import 'package:aveditor/models/effect_access_tier.dart';
import 'package:aveditor/models/text_composition.dart';
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:flutter/foundation.dart';

/// Line / block placement from the server catalog (spec §6).
@immutable
class TextPackLayout {
  const TextPackLayout({
    this.perLine = false,
    this.lineGapFactor = 0,
    this.maxLines,
    this.align = 'center',
  });

  /// One underlay strip per line (Journal). false = single block.
  final bool perLine;

  /// Extra gap between lines as a multiple of fontSize.
  final double lineGapFactor;

  final int? maxLines;

  /// `start` | `center` | `end`.
  final String align;

  Map<String, dynamic> toJson() => {
        if (perLine) 'perLine': true,
        if (lineGapFactor != 0) 'lineGapFactor': lineGapFactor,
        if (maxLines != null) 'maxLines': maxLines,
        if (align != 'center') 'align': align,
      };

  factory TextPackLayout.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TextPackLayout();
    return TextPackLayout(
      perLine: json['perLine'] as bool? ?? false,
      lineGapFactor: (json['lineGapFactor'] as num?)?.toDouble() ?? 0,
      maxLines: (json['maxLines'] as num?)?.toInt(),
      align: json['align'] as String? ?? 'center',
    );
  }
}

/// One downloadable / bundled text template (CapCut-style pack item).
@immutable
class TextTemplatePackItem {
  const TextTemplatePackItem({
    required this.id,
    required this.title,
    required this.style,
    this.kind = 'effect',
    this.accessTier = EffectAccessTier.free,
    this.lottieAsset,
    this.lottieUrl,
    this.previewUrl,
    this.downloadSizeBytes = 0,
    this.animation = TextEntranceAnimation.none,
    this.layout = const TextPackLayout(),
    this.sampleText,
    this.composition,
  });

  static const defaultEffectSampleText = 'Aa';
  static const defaultTemplateSampleText = 'Hello\nWorld';

  final String id;
  final String title;
  final TextStyleTemplate style;

  /// `effect` (static look) or `template` (effect + motion).
  final String kind;
  final EffectAccessTier accessTier;

  /// Back-compat: any paid access tier.
  bool get premium => accessTier.isPaid;

  /// Bundled Lottie path, e.g. `assets/text_packs/lottie/hearts.json`.
  final String? lottieAsset;

  /// Remote Lottie URL (relative to catalog [baseUrl] or absolute).
  final String? lottieUrl;
  final String? previewUrl;
  final int downloadSizeBytes;

  /// Default entrance animation when this pack is applied.
  final TextEntranceAnimation animation;

  /// Server-driven line geometry (per-line strips, gap, align).
  final TextPackLayout layout;

  /// Dashboard-editable body shown on app tiles and applied for crawl packs.
  final String? sampleText;

  /// CapCut-like multi-slot layout. When set, paint uses composition.
  final TextComposition? composition;

  bool get hasLottie =>
      (lottieAsset != null && lottieAsset!.isNotEmpty) ||
      (lottieUrl != null && lottieUrl!.isNotEmpty);

  bool get hasComposition =>
      composition != null && composition!.slots.isNotEmpty;

  /// Text shown on the studio grid tile (server [sampleText]).
  String get tilePreviewText {
    final sample = sampleText?.trim();
    if (sample != null && sample.isNotEmpty) {
      final lines = sample
          .split(RegExp(r'\n+'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .take(3)
          .toList();
      if (lines.isNotEmpty) return lines.join('\n');
    }
    if (hasComposition) return composition!.sampleText;
    return kind == 'template'
        ? defaultTemplateSampleText
        : defaultEffectSampleText;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'accessTier': accessTier.toJson(),
    'premium': accessTier.isPaid,
    'style': style.toJson(),
    if (lottieAsset != null) 'lottieAsset': lottieAsset,
    if (lottieUrl != null) 'lottieUrl': lottieUrl,
    if (previewUrl != null) 'previewUrl': previewUrl,
    'downloadSizeBytes': downloadSizeBytes,
    if (!animation.isNone) 'animation': animation.toJson(),
    if (layout.perLine ||
        layout.lineGapFactor != 0 ||
        layout.maxLines != null ||
        layout.align != 'center')
      'layout': layout.toJson(),
    if (sampleText != null && sampleText!.isNotEmpty) 'sampleText': sampleText,
    if (composition != null) 'composition': composition!.toJson(),
  };

  factory TextTemplatePackItem.fromJson(Map<String, dynamic> json) {
    final styleJson = Map<String, dynamic>.from(
      json['style'] as Map<String, dynamic>? ?? const {},
    );
    styleJson['id'] ??= json['id'];
    styleJson['label'] ??= json['title'] ?? json['id'];
    final kind = json['kind'] as String? ?? 'effect';
    final sample = (json['sampleText'] as String?)?.trim();
    final compositionJson = json['composition'] as Map<String, dynamic>?;
    final composition = compositionJson == null
        ? null
        : TextComposition.fromJson(compositionJson);

    return TextTemplatePackItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      kind: kind,
      accessTier: EffectAccessTier.fromJson(
        json['accessTier'] ?? json['plan'],
        legacyPremium: json['premium'] as bool?,
      ),
      style: TextStyleTemplate.fromJson(styleJson),
      lottieAsset: json['lottieAsset'] as String?,
      lottieUrl: json['lottieUrl'] as String?,
      previewUrl: json['previewUrl'] as String?,
      downloadSizeBytes: (json['downloadSizeBytes'] as num?)?.toInt() ?? 0,
      animation: TextEntranceAnimation.fromJson(
        json['animation'] as Map<String, dynamic>?,
      ),
      layout: TextPackLayout.fromJson(
        json['layout'] as Map<String, dynamic>?,
      ),
      composition: composition,
      sampleText: (sample != null && sample.isNotEmpty)
          ? sample
          : (composition != null
              ? composition.sampleText
              : (kind == 'template'
                  ? defaultTemplateSampleText
                  : defaultEffectSampleText)),
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
    final id = json['id'] as String;
    final defaultKind = id == 'templates' ? 'template' : 'effect';
    return TextTemplatePackCategory(
      id: id,
      title: json['title'] as String? ?? id,
      items: (json['items'] as List<dynamic>? ?? const []).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        map['kind'] ??= defaultKind;
        return TextTemplatePackItem.fromJson(map);
      }).toList(),
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
      version: (json['version'] as num?)?.toInt() ?? 1,
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
