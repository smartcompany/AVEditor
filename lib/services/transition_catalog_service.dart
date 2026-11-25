import 'dart:async';
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
  }) : _http = httpClient ?? http.Client(),
       _repository = repository;

  static final TransitionCatalogService instance = TransitionCatalogService();

  final http.Client _http;
  final TransitionRepository? _repository;
  final String bundledCatalogAsset;

  TransitionCatalog _catalog = const TransitionCatalog(version: 0, items: []);
  var _ready = false;
  var _syncing = false;
  String? _lastError;
  Future<void>? _initFuture;
  Future<void>? _syncFuture;

  TransitionCatalog get catalog => _catalog;
  bool get isReady => _ready;
  bool get isSyncing => _syncing;
  String? get lastError => _lastError;

  /// True when the picker has something to show (flat list or categories).
  bool get hasItems => _itemCount(_catalog) > 0;

  TransitionRepository get repository =>
      _repository ?? TransitionRepository(httpClient: _http);

  static int _itemCount(TransitionCatalog catalog) {
    if (catalog.items.isNotEmpty) return catalog.items.length;
    var n = 0;
    for (final cat in catalog.categories) {
      n += cat.items.length;
    }
    return n;
  }

  Future<void> ensureInitialized() async {
    if (_ready && hasItems) return;

    final existing = _initFuture;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {
        // Fall through and retry below.
      }
      if (_ready && hasItems) return;
    }

    final run = refresh();
    _initFuture = run;
    try {
      await run.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      debugPrint('TransitionCatalogService: init timed out');
      _lastError = 'timeout';
      // Never leave the picker on an empty "ready" state — try bundled once.
      if (!hasItems) {
        await _loadBundledIntoState();
      } else if (!_ready) {
        _ready = true;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('TransitionCatalogService: init failed: $error');
      if (!hasItems) {
        await _loadBundledIntoState();
      }
    } finally {
      _initFuture = null;
    }
  }

  /// Force a reload (picker retry / after hot reload empty state).
  Future<void> reload() async {
    _ready = false;
    _initFuture = null;
    await refresh(awaitRemote: true);
  }

  /// Panel open: keep showing cache, silently fetch remote. Only when
  /// [version] differs set [isSyncing] and replace (loading bar).
  Future<void> syncOnPanelOpen() async {
    await ensureInitialized();
    final base =
        TextTemplatePackService.instance.remoteBaseUrl.trim().isNotEmpty
        ? TextTemplatePackService.instance.remoteBaseUrl.trim()
        : TextTemplatePackService.defaultRemoteBaseUrl;
    if (base.isEmpty) return;

    final existing = _syncFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final run = _syncRemoteVersion(base);
    _syncFuture = run;
    try {
      await run;
    } finally {
      if (identical(_syncFuture, run)) _syncFuture = null;
    }
  }

  Future<void> _syncRemoteVersion(String base) async {
    try {
      final remote = await repository.fetchCatalog(base);
      if (_itemCount(remote) == 0) return;
      if (remote.version == _catalog.version) return;

      _syncing = true;
      notifyListeners();
      try {
        _catalog = TransitionCatalog(
          version: remote.version,
          baseUrl:
              remote.baseUrl.isNotEmpty ? remote.baseUrl : _catalog.baseUrl,
          items: remote.items.isNotEmpty ? remote.items : _allItems(remote),
          categories: remote.categories,
        );
        notifyListeners();
      } finally {
        _syncing = false;
        notifyListeners();
      }
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TransitionCatalogService: panel sync failed: $error');
      if (_syncing) {
        _syncing = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh({bool awaitRemote = false}) async {
    _lastError = null;
    try {
      // Show bundled catalog immediately so the picker is never blocked on
      // the network.
      final bundled = await _loadBundled().timeout(const Duration(seconds: 3));
      _catalog = bundled;
      _ready = true;
      notifyListeners();

      final base =
          TextTemplatePackService.instance.remoteBaseUrl.trim().isNotEmpty
          ? TextTemplatePackService.instance.remoteBaseUrl.trim()
          : TextTemplatePackService.defaultRemoteBaseUrl;

      if (awaitRemote) {
        await _mergeRemote(base, bundled);
      } else {
        unawaited(_mergeRemote(base, bundled));
      }
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TransitionCatalogService: refresh failed: $error');
      await _loadBundledIntoState();
    }
  }

  Future<void> _loadBundledIntoState() async {
    try {
      _catalog = await _loadBundled().timeout(const Duration(seconds: 2));
    } catch (bundledError) {
      debugPrint(
        'TransitionCatalogService: bundled load failed: $bundledError',
      );
      if (!hasItems) {
        _catalog = const TransitionCatalog(version: 0, items: []);
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _mergeRemote(String base, TransitionCatalog bundled) async {
    try {
      final remote = await repository.fetchCatalog(base);
      if (_itemCount(remote) == 0) return;
      if (remote.version == _catalog.version) return;
      _catalog = TransitionCatalog(
        version: remote.version,
        baseUrl: remote.baseUrl.isNotEmpty ? remote.baseUrl : bundled.baseUrl,
        items: remote.items.isNotEmpty ? remote.items : _allItems(remote),
        categories: remote.categories,
      );
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TransitionCatalogService: remote refresh failed: $error');
    }
  }

  TransitionItem? itemById(String? id) => _catalog.byId(id);

  String? resolvedThumbnailUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.thumbnailUrl);

  String? resolvedAssetUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.assetUrl);

  String? resolvedPreviewUrl(TransitionItem item) =>
      _catalog.resolveUrl(item.previewUrl);

  /// Resolves an effect name for a legacy transition id, or null for a hard
  /// cut. Prefer [TransitionEngine] for applied transitions.
  String? effectNameFor(String? transitionId) {
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
        return item.effectName.isEmpty ? 'fade' : item.effectName;
      case TransitionRendererKind.primitive:
      case TransitionRendererKind.shader:
      case TransitionRendererKind.custom:
      case TransitionRendererKind.asset:
        if (item.effectName.isNotEmpty) return item.effectName;
        debugPrint(
          'TransitionCatalogService: ${item.renderer.name} "${item.id}" '
          'has no export bridge; falling back to fade',
        );
        return 'fade';
    }
  }

  Future<TransitionCatalog> _loadBundled() async {
    final raw = await rootBundle.loadString(bundledCatalogAsset);
    return TransitionCatalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static List<TransitionItem> _allItems(TransitionCatalog catalog) {
    if (catalog.items.isNotEmpty) return catalog.items;
    return [for (final cat in catalog.categories) ...cat.items];
  }
}
