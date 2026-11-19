/// Server-driven subscription plan copy + flags (`/api/plans`, credits bootstrap).
class RemotePlan {
  const RemotePlan({
    required this.id,
    required this.title,
    required this.titles,
    required this.subtitle,
    required this.benefits,
    required this.editingUnlocked,
    required this.aiEnabled,
    required this.monthlyCredits,
    this.enabled = true,
    this.storeProductIdMonthly = '',
    this.storeProductIdAnnual = '',
  });

  final String id;
  final String title;
  final Map<String, String> titles;
  final Map<String, String> subtitle;
  final List<Map<String, String>> benefits;
  final bool editingUnlocked;
  final bool aiEnabled;
  final int monthlyCredits;
  /// When false, hide this paid tier from the paywall.
  final bool enabled;
  /// App Store / Play Product ID (ASC 제품 ID) for monthly SKU.
  final String storeProductIdMonthly;
  /// App Store / Play Product ID for annual SKU.
  final String storeProductIdAnnual;

  factory RemotePlan.fromJson(Map<String, dynamic> json) {
    Map<String, String> localeMap(dynamic raw) {
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    }

    final benefitsRaw = json['benefits'];
    final benefits = <Map<String, String>>[];
    if (benefitsRaw is List) {
      for (final item in benefitsRaw) {
        final map = localeMap(item);
        if (map.isNotEmpty) benefits.add(map);
      }
    }

    return RemotePlan(
      id: (json['id'] as String?) ?? 'free',
      title: (json['title'] as String?) ?? '',
      titles: localeMap(json['titles']),
      subtitle: localeMap(json['subtitle']),
      benefits: benefits,
      editingUnlocked: json['editingUnlocked'] as bool? ?? false,
      aiEnabled: json['aiEnabled'] as bool? ?? false,
      monthlyCredits: (json['monthlyCredits'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      storeProductIdMonthly:
          (json['storeProductIdMonthly'] as String?)?.trim() ?? '',
      storeProductIdAnnual:
          (json['storeProductIdAnnual'] as String?)?.trim() ?? '',
    );
  }

  String localizedTitle(String lang) {
    return titles[lang] ?? titles['en'] ?? title;
  }

  String localizedSubtitle(String lang, {required int credits}) {
    final raw = subtitle[lang] ?? subtitle['en'] ?? '';
    return raw.replaceAll('{credits}', '$credits');
  }

  List<String> localizedBenefits(String lang, {required int credits}) {
    return [
      for (final b in benefits)
        (b[lang] ?? b['en'] ?? '').replaceAll('{credits}', '$credits'),
    ].where((s) => s.trim().isNotEmpty).toList(growable: false);
  }
}
