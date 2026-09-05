/// One cut-transition option from the server (or bundled) catalog.
class TransitionItem {
  const TransitionItem({
    required this.id,
    required this.title,
    required this.ffmpegName,
    required this.defaultDurationMs,
    required this.accent,
  });

  final String id;
  final String title;

  /// FFmpeg `xfade` transition name; empty for a hard cut.
  final String ffmpegName;
  final int defaultDurationMs;
  final String accent;

  bool get isNone => id == 'none' || ffmpegName.isEmpty;

  factory TransitionItem.fromJson(Map<String, dynamic> json) {
    return TransitionItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      ffmpegName: json['ffmpegName'] as String? ?? '',
      defaultDurationMs: (json['defaultDurationMs'] as num?)?.toInt() ?? 500,
      accent: json['accent'] as String? ?? '#6B7280',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'ffmpegName': ffmpegName,
        'defaultDurationMs': defaultDurationMs,
        'accent': accent,
      };
}

class TransitionCatalog {
  const TransitionCatalog({
    required this.version,
    required this.items,
  });

  final int version;
  final List<TransitionItem> items;

  factory TransitionCatalog.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] as List<dynamic>? ?? const [];
    return TransitionCatalog(
      version: (json['version'] as num?)?.toInt() ?? 1,
      items: raw
          .whereType<Map<String, dynamic>>()
          .map(TransitionItem.fromJson)
          .toList(growable: false),
    );
  }

  TransitionItem? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
