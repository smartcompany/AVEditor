import 'dart:convert';

import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/services/transition_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Loads cut-transition definitions from a bundled asset + optional remote catalog.
class TransitionCatalogService extends ChangeNotifier {
  TransitionCatalogService({
    http.Client? httpClient,
    TransitionRepository? repository,
    this.bundledCatalogAsset = 'assets/transitions/catalog.json',
  })  : _http = httpClient ?? http.Client(),
        _repository = repository;

  static final TransitionCatalogService instance = TransitionCatalogService();

  final http.Client _http;
  final TransitionRepository? _repository;
  final String bundledCatalogAsset;

  TransitionCatalog _catalog = const TransitionCatalog(version: 0, items: []);
  var _ready = false;
  String? _lastError;

  TransitionCatalog get catalog => _catalog;
  bool get isReady => _ready;
  String? get lastError => _lastError;

  TransitionRepository get repository =>
      _repository ?? TransitionRepository(httpClient: _http);

  Future<void> ensureInitialized() async {
    if (_ready) return;
    await refresh();
  }

  Future<void> refresh() async {
    _lastError = null;
    try {
      final bundled = await _loadBundled();
      var catalog = bundled;

      final base =
          TextTemplatePackService.instance.remoteBaseUrl.trim().isNotEmpty
              ? TextTemplatePackService.instance.remoteBaseUrl.trim()
              : TextTemplatePackService.defaultRemoteBaseUrl;

      try {
        final remote = await repository.fetchCatalog(base);
        catalog = _merge(bundled, remote);
      } catch (error) {
        _lastError = error.toString();
      }

      _catalog = catalog;
      _ready = true;
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      _catalog = await _loadBundled();
      _ready = true;
      notifyListeners();
    }
  }

  TransitionItem? itemById(String? id) => _catalog.byId(id);

  String? resolvedThumbnailUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.thumbnailUrl);

  String? resolvedAssetUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.assetUrl);

  String? resolvedPreviewUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.previewUrl);

  /// Resolves an FFmpeg xfade name for a legacy transition id, or null for a
  /// hard cut. Prefer [TransitionEngine] for applied transitions.
  String? ffmpegNameFor(String? transitionId) {
    if (transitionId == null ||
        transitionId.isEmpty ||
        transitionId == 'none') {
      return null;
    }
    final item = _catalog.byId(transitionId);
    if (item == null) {
      return transitionId;
    }
    switch (item.renderer) {
      case TransitionRendererKind.cut:
        return null;
      case TransitionRendererKind.xfade:
        return item.ffmpegName.isEmpty ? 'fade' : item.ffmpegName;
      case TransitionRendererKind.primitive:
      case TransitionRendererKind.shader:
      case TransitionRendererKind.custom:
      case TransitionRendererKind.asset:
        if (item.ffmpegName.isNotEmpty) return item.ffmpegName;
        debugPrint(
          'TransitionCatalogService: ${item.renderer.name} "${item.id}" '
          'has no export bridge; falling back to fade',
        );
        return 'fade';
    }
  }

  Future<TransitionCatalog> _loadBundled() async {
    final raw = await rootBundle.loadString(bundledCatalogAsset);
    return TransitionCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  /// Remote ids win; remote category order preferred when present.
  TransitionCatalog _merge(TransitionCatalog bundled, TransitionCatalog remote) {
    if (remote.items.isEmpty && remote.categories.isEmpty) return bundled;

    final byId = <String, TransitionItem>{
      for (final item in bundled.items) item.id: item,
    };
    for (final item in _allItems(remote)) {
      byId[item.id] = item;
    }

    final categories = <TransitionCategory>[];
    final seenCategoryIds = <String>{};

    void addCategory(TransitionCategory category, {required bool remoteFirst}) {
      if (!seenCategoryIds.add(category.id)) {
        final index = categories.indexWhere((c) => c.id == category.id);
        if (index < 0) return;
        final existing = categories[index];
        final itemIds = <String>{for (final i in existing.items) i.id};
        final merged = [
          ...existing.items,
          for (final item in category.items)
            if (itemIds.add(item.id)) byId[item.id] ?? item,
        ];
        categories[index] = TransitionCategory(
          id: existing.id,
          title: remoteFirst ? existing.title : category.title,
          items: [
            for (final item in merged) byId[item.id] ?? item,
          ],
        );
        return;
      }

      categories.add(
        TransitionCategory(
          id: category.id,
          title: category.title,
          items: [
            for (final item in category.items) byId[item.id] ?? item,
          ],
        ),
      );
    }

    for (final cat in remote.displayCategories) {
      addCategory(cat, remoteFirst: true);
    }
    for (final cat in bundled.displayCategories) {
      addCategory(cat, remoteFirst: false);
    }

    final ordered = <TransitionItem>[];
    final seen = <String>{};
    for (final item in _allItems(remote)) {
      ordered.add(byId[item.id]!);
      seen.add(item.id);
    }
    for (final item in bundled.items) {
      if (seen.add(item.id)) ordered.add(byId[item.id]!);
    }

    return TransitionCatalog(
      version:
          remote.version >= bundled.version ? remote.version : bundled.version,
      baseUrl: remote.baseUrl.isNotEmpty ? remote.baseUrl : bundled.baseUrl,
      items: ordered,
      categories: categories,
    );
  }

  static List<TransitionItem> _allItems(TransitionCatalog catalog) {
    if (catalog.items.isNotEmpty) return catalog.items;
    return [for (final cat in catalog.categories) ...cat.items];
  }
}
