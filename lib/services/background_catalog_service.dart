import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/background_template.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Loads still-background templates (bundled + remote) for the gallery picker.
class BackgroundCatalogService extends ChangeNotifier {
  BackgroundCatalogService({
    http.Client? httpClient,
    this.bundledCatalogAsset = 'assets/backgrounds/catalog.json',
  }) : _http = httpClient ?? http.Client();

  static final BackgroundCatalogService instance = BackgroundCatalogService();

  final http.Client _http;
  final String bundledCatalogAsset;

  BackgroundCatalog _catalog = BackgroundCatalog.empty;
  var _ready = false;
  String? _lastError;

  BackgroundCatalog get catalog => _catalog;
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
      final base = TextTemplatePackService.instance.remoteBaseUrl.trim().isEmpty
          ? TextTemplatePackService.defaultRemoteBaseUrl
          : TextTemplatePackService.instance.remoteBaseUrl.trim();
      try {
        final remote = await _fetchRemote(base);
        if (remote.version >= bundled.version) {
          catalog = remote;
        }
      } catch (error) {
        _lastError = error.toString();
      }
      _catalog = catalog;
      _ready = true;
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      _catalog = BackgroundCatalog.empty;
      _ready = true;
      notifyListeners();
    }
  }

  /// Resolves a local file path for [item] (bundled asset copy or download).
  Future<String> materializeFile(BackgroundTemplate item) async {
    final relative = item.imageUrl.replaceFirst(RegExp(r'^/+'), '');
    final bundledAsset = 'assets/$relative';
    try {
      final data = await rootBundle.load(bundledAsset);
      final dir = await getTemporaryDirectory();
      final out = File(
        p.join(dir.path, 'bg_${item.id}_${p.basename(relative)}'),
      );
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return out.path;
    } catch (_) {
      // Fall through to remote download.
    }

    final url = _catalog.resolveUrl(item.imageUrl);
    if (url.isEmpty || !url.startsWith('http')) {
      throw StateError('background_missing:${item.id}');
    }
    final res = await _http.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('background_download:${res.statusCode}');
    }
    final dir = await getTemporaryDirectory();
    final ext = p.extension(Uri.parse(url).path);
    final out = File(
      p.join(
        dir.path,
        'bg_${item.id}${ext.isEmpty ? '.png' : ext}',
      ),
    );
    await out.writeAsBytes(res.bodyBytes, flush: true);
    return out.path;
  }

  Future<BackgroundCatalog> _loadBundled() async {
    final raw = await rootBundle.loadString(bundledCatalogAsset);
    return BackgroundCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<BackgroundCatalog> _fetchRemote(String baseUrl) async {
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse('${base}backgrounds/catalog.json');
    final res = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('background_catalog_http:${res.statusCode}');
    }
    final catalog = BackgroundCatalog.fromJson(
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
    );
    if (catalog.baseUrl.isEmpty) {
      return BackgroundCatalog(
        version: catalog.version,
        baseUrl: base,
        items: catalog.items,
      );
    }
    return catalog;
  }
}
