import 'dart:convert';

import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Loads cut-transition options from a bundled asset and optional remote catalog.
class TransitionCatalogService extends ChangeNotifier {
  TransitionCatalogService({
    http.Client? httpClient,
    this.bundledCatalogAsset = 'assets/transitions/catalog.json',
  }) : _http = httpClient ?? http.Client();

  static final TransitionCatalogService instance = TransitionCatalogService();

  final http.Client _http;
  final String bundledCatalogAsset;

  TransitionCatalog _catalog = const TransitionCatalog(version: 0, items: []);
  var _ready = false;
  String? _lastError;

  TransitionCatalog get catalog => _catalog;
  bool get isReady => _ready;
  String? get lastError => _lastError;

  Future<void> ensureInitialized() async {
    if (_ready) return;
    await refresh();
  }

  Future<void> refresh() async {
    _lastError = null;
    try {
      final bundled = await _loadBundled();
      var catalog = bundled;

      final base = TextTemplatePackService.instance.remoteBaseUrl.trim().isNotEmpty
          ? TextTemplatePackService.instance.remoteBaseUrl.trim()
          : TextTemplatePackService.defaultRemoteBaseUrl;

      try {
        final remote = await _fetchRemote(base);
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

  /// Resolves an FFmpeg xfade name for [transitionId], or null for a hard cut.
  String? ffmpegNameFor(String? transitionId) {
    if (transitionId == null || transitionId.isEmpty || transitionId == 'none') {
      return null;
    }
    final item = _catalog.byId(transitionId);
    if (item != null) {
      return item.isNone ? null : item.ffmpegName;
    }
    // Offline / unknown id: treat known ids as their ffmpeg names.
    return transitionId;
  }

  Future<TransitionCatalog> _loadBundled() async {
    final raw = await rootBundle.loadString(bundledCatalogAsset);
    return TransitionCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<TransitionCatalog> _fetchRemote(String baseUrl) async {
    final root = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse('${root}transitions/catalog.json');
    final response = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return TransitionCatalog.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  TransitionCatalog _merge(TransitionCatalog bundled, TransitionCatalog remote) {
    if (remote.items.isEmpty) return bundled;
    final byId = <String, TransitionItem>{
      for (final item in bundled.items) item.id: item,
    };
    for (final item in remote.items) {
      byId[item.id] = item;
    }
    // Prefer remote order when present.
    final ordered = <TransitionItem>[];
    final seen = <String>{};
    for (final item in remote.items) {
      ordered.add(byId[item.id]!);
      seen.add(item.id);
    }
    for (final item in bundled.items) {
      if (seen.add(item.id)) ordered.add(item);
    }
    return TransitionCatalog(
      version: remote.version >= bundled.version ? remote.version : bundled.version,
      items: ordered,
    );
  }
}
