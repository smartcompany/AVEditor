/// Shared easing curves for primitive transition layers.
enum TransitionEasing {
  linear,
  easeIn,
  easeOut,
  easeInOut,
  cubic,
  bounce,
  elastic,
  cubicBezier;

  static TransitionEasing fromJson(String? raw) {
    switch (raw) {
      case 'easeIn':
        return TransitionEasing.easeIn;
      case 'easeOut':
        return TransitionEasing.easeOut;
      case 'easeInOut':
        return TransitionEasing.easeInOut;
      case 'cubic':
        return TransitionEasing.cubic;
      case 'bounce':
        return TransitionEasing.bounce;
      case 'elastic':
        return TransitionEasing.elastic;
      case 'cubicBezier':
      case 'cubic-bezier':
        return TransitionEasing.cubicBezier;
      case 'linear':
      default:
        return TransitionEasing.linear;
    }
  }

  String toJson() => name;
}

/// Which clip a primitive layer animates.
enum TransitionLayerTarget {
  outgoing,
  incoming,
  both;

  static TransitionLayerTarget fromJson(String? raw) {
    switch (raw) {
      case 'incoming':
        return TransitionLayerTarget.incoming;
      case 'both':
        return TransitionLayerTarget.both;
      case 'outgoing':
      default:
        return TransitionLayerTarget.outgoing;
    }
  }

  String toJson() => name;
}

/// Animatable properties for [TransitionRendererKind.primitive].
enum TransitionProperty {
  opacity,
  scale,
  translateX,
  translateY,
  rotation,
  blur,
  brightness,
  saturation,
  contrast;

  static TransitionProperty? fromJson(String? raw) {
    if (raw == null) return null;
    for (final value in TransitionProperty.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

/// Hybrid renderer kinds. Server picks one; the app implements the code path.
enum TransitionRendererKind {
  cut,
  xfade,
  primitive,
  shader,
  custom,
  asset;

  static TransitionRendererKind fromJson(String? raw) {
    switch (raw) {
      case 'xfade':
        return TransitionRendererKind.xfade;
      case 'primitive':
        return TransitionRendererKind.primitive;
      case 'shader':
        return TransitionRendererKind.shader;
      case 'custom':
        return TransitionRendererKind.custom;
      case 'asset':
        return TransitionRendererKind.asset;
      case 'cut':
      default:
        return TransitionRendererKind.cut;
    }
  }

  String toJson() => name;
}

class TransitionLayer {
  const TransitionLayer({
    required this.property,
    required this.from,
    required this.to,
    this.easing = TransitionEasing.linear,
    this.target = TransitionLayerTarget.outgoing,
    this.bezier,
  });

  final TransitionProperty property;
  final double from;
  final double to;
  final TransitionEasing easing;
  final TransitionLayerTarget target;

  /// Optional cubic-bezier control points `[x1,y1,x2,y2]` when [easing] is
  /// [TransitionEasing.cubicBezier].
  final List<double>? bezier;

  factory TransitionLayer.fromJson(Map<String, dynamic> json) {
    final property = TransitionProperty.fromJson(json['property'] as String?);
    if (property == null) {
      throw FormatException('Unknown transition layer property: ${json['property']}');
    }
    final bezierRaw = json['bezier'] as List<dynamic>?;
    return TransitionLayer(
      property: property,
      from: (json['from'] as num?)?.toDouble() ?? 0,
      to: (json['to'] as num?)?.toDouble() ?? 0,
      easing: TransitionEasing.fromJson(json['easing'] as String?),
      target: TransitionLayerTarget.fromJson(json['target'] as String?),
      bezier: bezierRaw
          ?.map((e) => (e as num).toDouble())
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'property': property.name,
        'from': from,
        'to': to,
        'easing': easing.toJson(),
        'target': target.toJson(),
        if (bezier != null) 'bezier': bezier,
      };
}

class TransitionParameterDef {
  const TransitionParameterDef({
    required this.key,
    required this.type,
    required this.defaultValue,
    this.min,
    this.max,
  });

  final String key;
  final String type; // double | int | bool | enum
  final double defaultValue;
  final double? min;
  final double? max;

  factory TransitionParameterDef.fromJson(String key, Map<String, dynamic> json) {
    return TransitionParameterDef(
      key: key,
      type: json['type'] as String? ?? 'double',
      defaultValue: (json['default'] as num?)?.toDouble() ?? 0,
      min: (json['min'] as num?)?.toDouble(),
      max: (json['max'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'default': defaultValue,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
      };
}

class TransitionControl {
  const TransitionControl({
    required this.type,
    required this.key,
    required this.label,
    this.min,
    this.max,
    this.defaultValue,
  });

  final String type; // slider | toggle | ...
  final String key;
  final String label;
  final double? min;
  final double? max;
  final double? defaultValue;

  factory TransitionControl.fromJson(Map<String, dynamic> json) {
    return TransitionControl(
      type: json['type'] as String? ?? 'slider',
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? json['key'] as String? ?? '',
      min: (json['min'] as num?)?.toDouble(),
      max: (json['max'] as num?)?.toDouble(),
      defaultValue: (json['default'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'key': key,
        'label': label,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (defaultValue != null) 'default': defaultValue,
      };
}

/// Catalog definition for one transition effect (server source of truth).
///
/// Project instances store [AppliedTransition] (id + version + params), not a
/// live pointer into the latest catalog entry.
class TransitionItem {
  const TransitionItem({
    required this.id,
    required this.title,
    required this.ffmpegName,
    required this.defaultDurationMs,
    required this.accent,
    this.renderer = TransitionRendererKind.xfade,
    this.category = 'basic',
    this.minDurationMs = 50,
    this.maxDurationMs = 5000,
    this.premium = false,
    this.thumbnailUrl,
    this.previewUrl,
    this.assetUrl,
    this.downloadSizeBytes = 0,
    this.itemVersion = 1,
    this.shader,
    this.customId,
    this.layers = const [],
    this.parameters = const {},
    this.controls = const [],
  });

  final String id;
  final String title;
  final String category;

  /// Pins definition revisions; projects store this on apply.
  final int itemVersion;

  final TransitionRendererKind renderer;

  /// FFmpeg `xfade` name when [renderer] is [TransitionRendererKind.xfade],
  /// or an export bridge for unsupported primitive/shader effects.
  final String ffmpegName;

  /// Named shader / custom plugin id when using hybrid renderers.
  final String? shader;
  final String? customId;

  final int defaultDurationMs;
  final int minDurationMs;
  final int maxDurationMs;
  final String accent;
  final bool premium;
  final String? thumbnailUrl;
  final String? previewUrl;
  final String? assetUrl;
  final int downloadSizeBytes;

  final List<TransitionLayer> layers;
  final Map<String, TransitionParameterDef> parameters;
  final List<TransitionControl> controls;

  /// Back-compat alias used by older callers.
  @Deprecated('Use itemVersion')
  int get version => itemVersion;

  bool get isNone =>
      id == 'none' ||
      renderer == TransitionRendererKind.cut ||
      (ffmpegName.isEmpty &&
          renderer != TransitionRendererKind.asset &&
          renderer != TransitionRendererKind.shader &&
          renderer != TransitionRendererKind.custom &&
          renderer != TransitionRendererKind.primitive);

  bool get needsDownload =>
      renderer == TransitionRendererKind.asset &&
      assetUrl != null &&
      assetUrl!.isNotEmpty;

  Map<String, double> defaultParameters() => {
        for (final entry in parameters.entries) entry.key: entry.value.defaultValue,
      };

  factory TransitionItem.fromJson(Map<String, dynamic> json) {
    final ffmpeg = json['ffmpegName'] as String? ?? '';
    var renderer = TransitionRendererKind.fromJson(
      json['renderer'] as String? ?? json['effectType'] as String?,
    );
    // Legacy catalogs: empty ffmpegName ⇒ cut; otherwise xfade.
    if (json['renderer'] == null && json['effectType'] == null) {
      renderer = ffmpeg.isEmpty
          ? TransitionRendererKind.cut
          : TransitionRendererKind.xfade;
    }

    final defaultMs = _durationMs(
      json,
      defaultKey: 'defaultDurationMs',
      secondsKey: 'duration',
      nestedDefaultKey: 'default',
      fallback: 500,
    );
    final minMs = _durationMs(
      json,
      defaultKey: 'minDurationMs',
      secondsKey: 'duration',
      nestedDefaultKey: 'min',
      fallback: 50,
    );
    final maxMs = _durationMs(
      json,
      defaultKey: 'maxDurationMs',
      secondsKey: 'duration',
      nestedDefaultKey: 'max',
      fallback: 5000,
    );

    final paramsRaw = json['parameters'];
    final parameters = <String, TransitionParameterDef>{};
    if (paramsRaw is Map) {
      for (final entry in paramsRaw.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Map) {
          parameters[key] = TransitionParameterDef.fromJson(
            key,
            Map<String, dynamic>.from(value),
          );
        }
      }
    }

    final layersRaw = json['layers'] as List<dynamic>? ?? const [];
    final layers = <TransitionLayer>[];
    for (final raw in layersRaw) {
      if (raw is! Map) continue;
      try {
        layers.add(TransitionLayer.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {
        // Ignore unknown layer properties so catalogs stay forward-compatible.
      }
    }

    final controlsRaw = json['controls'] as List<dynamic>? ?? const [];
    final controls = controlsRaw
        .whereType<Map>()
        .map((e) => TransitionControl.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);

    return TransitionItem(
      id: json['id'] as String,
      title: json['title'] as String? ??
          json['name'] as String? ??
          json['id'] as String,
      category: json['category'] as String? ?? 'basic',
      ffmpegName: ffmpeg,
      defaultDurationMs: defaultMs,
      accent: json['accent'] as String? ?? '#6B7280',
      renderer: renderer,
      minDurationMs: minMs,
      maxDurationMs: maxMs < minMs ? minMs : maxMs,
      premium: json['premium'] as bool? ?? false,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      previewUrl: json['previewUrl'] as String?,
      assetUrl: json['assetUrl'] as String?,
      downloadSizeBytes: (json['downloadSizeBytes'] as num?)?.toInt() ?? 0,
      itemVersion: (json['version'] as num?)?.toInt() ??
          (json['itemVersion'] as num?)?.toInt() ??
          1,
      shader: json['shader'] as String?,
      customId: json['customId'] as String? ?? json['custom'] as String?,
      layers: layers,
      parameters: parameters,
      controls: controls,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'name': title,
        'category': category,
        'version': itemVersion,
        'itemVersion': itemVersion,
        'renderer': renderer.toJson(),
        // Legacy mirror so older clients keep working.
        'effectType': renderer == TransitionRendererKind.xfade
            ? 'xfade'
            : renderer == TransitionRendererKind.asset
                ? 'asset'
                : renderer == TransitionRendererKind.cut
                    ? 'cut'
                    : renderer.toJson(),
        'ffmpegName': ffmpegName,
        'defaultDurationMs': defaultDurationMs,
        'minDurationMs': minDurationMs,
        'maxDurationMs': maxDurationMs,
        'accent': accent,
        'premium': premium,
        if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
        if (previewUrl != null) 'previewUrl': previewUrl,
        if (assetUrl != null) 'assetUrl': assetUrl,
        if (shader != null) 'shader': shader,
        if (customId != null) 'customId': customId,
        'downloadSizeBytes': downloadSizeBytes,
        if (layers.isNotEmpty)
          'layers': layers.map((e) => e.toJson()).toList(growable: false),
        if (parameters.isNotEmpty)
          'parameters': {
            for (final e in parameters.entries) e.key: e.value.toJson(),
          },
        if (controls.isNotEmpty)
          'controls': controls.map((e) => e.toJson()).toList(growable: false),
      };

  static int _durationMs(
    Map<String, dynamic> json, {
    required String defaultKey,
    required String secondsKey,
    required String nestedDefaultKey,
    required int fallback,
  }) {
    final flat = (json[defaultKey] as num?)?.toInt();
    if (flat != null) return flat;
    final duration = json[secondsKey];
    if (duration is Map) {
      final seconds = duration[nestedDefaultKey];
      if (seconds is num) return (seconds * 1000).round();
    }
    return fallback;
  }
}

class TransitionCategory {
  const TransitionCategory({
    required this.id,
    required this.title,
    required this.items,
  });

  final String id;
  final String title;
  final List<TransitionItem> items;

  factory TransitionCategory.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] as List<dynamic>? ?? const [];
    return TransitionCategory(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      items: [
        for (final e in raw)
          if (e is Map) TransitionItem.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }
}

class TransitionCatalog {
  const TransitionCatalog({
    required this.version,
    required this.items,
    this.baseUrl = '',
    this.categories = const [],
  });

  final int version;
  final String baseUrl;
  final List<TransitionItem> items;
  final List<TransitionCategory> categories;

  /// Categories for UI; synthesizes a single "All" group when none provided.
  List<TransitionCategory> get displayCategories {
    if (categories.isNotEmpty) return categories;
    if (items.isEmpty) return const [];
    return [
      TransitionCategory(id: 'all', title: 'All', items: items),
    ];
  }

  factory TransitionCatalog.fromJson(Map<String, dynamic> json) {
    final baseUrl = json['baseUrl'] as String? ?? '';
    final flatRaw = json['items'] as List<dynamic>? ?? const [];
    final flat = [
      for (final e in flatRaw)
        if (e is Map) TransitionItem.fromJson(Map<String, dynamic>.from(e)),
    ];

    final catRaw = json['categories'] as List<dynamic>? ?? const [];
    final categories = [
      for (final e in catRaw)
        if (e is Map)
          TransitionCategory.fromJson(Map<String, dynamic>.from(e)),
    ];

    final items = flat.isNotEmpty
        ? flat
        : _uniquePreferringRich(categories);

    return TransitionCatalog(
      version: (json['version'] as num?)?.toInt() ?? 1,
      baseUrl: baseUrl,
      items: items,
      categories: categories,
    );
  }

  /// When the same id appears in multiple categories, keep the richest
  /// definition (parameters / controls / layers) so Trending teaser rows do
  /// not wipe the canonical entry.
  static List<TransitionItem> _uniquePreferringRich(
    List<TransitionCategory> categories,
  ) {
    final byId = <String, TransitionItem>{};
    for (final cat in categories) {
      for (final item in cat.items) {
        final existing = byId[item.id];
        if (existing == null || _richness(item) > _richness(existing)) {
          byId[item.id] = item;
        }
      }
    }
    return byId.values.toList(growable: false);
  }

  static int _richness(TransitionItem item) =>
      item.controls.length * 4 +
      item.parameters.length * 3 +
      item.layers.length * 2 +
      (item.ffmpegName.isNotEmpty ? 1 : 0);

  TransitionItem? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    TransitionItem? best;
    var bestScore = -1;
    void consider(TransitionItem item) {
      if (item.id != id) return;
      final score = _richness(item);
      if (score > bestScore) {
        best = item;
        bestScore = score;
      }
    }

    for (final item in items) {
      consider(item);
    }
    for (final cat in categories) {
      for (final item in cat.items) {
        consider(item);
      }
    }
    return best;
  }

  /// Prefer exact version match; otherwise newest catalog entry for [id].
  TransitionItem? byIdVersion(String? id, int? version) {
    final latest = byId(id);
    if (latest == null || version == null) return latest;
    if (latest.itemVersion == version) return latest;
    // Catalog currently stores one row per id; version pin still travels with
    // the project so a future multi-version API can resolve accurately.
    return latest;
  }

  String? resolveUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final root = baseUrl.trim();
    if (root.isEmpty) return path;
    final normalized = root.endsWith('/') ? root : '$root/';
    final relative = path.startsWith('/') ? path.substring(1) : path;
    return '$normalized$relative';
  }
}
