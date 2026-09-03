import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loads Word Art catalogs from bundled assets and an optional remote base URL.
///
/// Lottie files are cached under the app documents directory so packs work
/// offline after the first download (Giphy-style install flow).
class TextTemplatePackService extends ChangeNotifier {
  TextTemplatePackService({
    http.Client? httpClient,
    this.bundledCatalogAsset = 'assets/text_packs/catalog.json',
  }) : _http = httpClient ?? http.Client();

  static const remoteBaseUrlKey = 'text_template_pack_base_url';
  static const installedKey = 'text_template_pack_installed';

  /// Production pack API on Vercel.
  static const defaultRemoteBaseUrl = 'https://aveditorserver.vercel.app/';

  static final TextTemplatePackService instance = TextTemplatePackService();

  final http.Client _http;
  final String bundledCatalogAsset;

  TextTemplatePackCatalog _catalog = TextTemplatePackCatalog.empty();
  final Set<String> _installed = {};
  final Set<String> _downloading = {};
  String _remoteBaseUrl = '';
  var _ready = false;
  String? _lastError;

  TextTemplatePackCatalog get catalog => _catalog;
  bool get isReady => _ready;
  String? get lastError => _lastError;
  String get remoteBaseUrl => _remoteBaseUrl;

  Future<void> ensureInitialized() async {
    if (_ready) return;
    await refresh();
  }

  Future<void> refresh() async {
    _lastError = null;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(remoteBaseUrlKey);
    const fromDefine = String.fromEnvironment(
      'TEXT_PACK_BASE_URL',
      defaultValue: defaultRemoteBaseUrl,
    );
    _remoteBaseUrl = (stored != null && stored.isNotEmpty)
        ? stored
        : fromDefine;
    _installed
      ..clear()
      ..addAll(prefs.getStringList(installedKey) ?? const []);

    try {
      final bundled = await _loadBundledCatalog();
      var catalog = bundled;

      if (_remoteBaseUrl.trim().isNotEmpty) {
        try {
          final remote = await _fetchRemoteCatalog(_remoteBaseUrl.trim());
          catalog = _mergeCatalogs(bundled, remote);
        } catch (error) {
          _lastError = error.toString();
        }
      }

      _catalog = catalog;
      _ready = true;
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      _catalog = TextTemplatePackCatalog.empty();
      _ready = true;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setRemoteBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(remoteBaseUrlKey);
    } else {
      await prefs.setString(remoteBaseUrlKey, trimmed);
    }
    await refresh();
  }

  TextTemplatePackItem? itemById(String? id) => _catalog.itemById(id);

  TextStyleTemplate? styleFor(String? packItemId) =>
      itemById(packItemId)?.style;

  bool isInstalled(TextTemplatePackItem item) {
    if (item.lottieAsset != null && item.lottieAsset!.isNotEmpty) {
      return true;
    }
    if (!item.hasLottie) return true;
    return _installed.contains(item.id);
  }

  bool isDownloading(String id) => _downloading.contains(id);

  /// Local file path for a downloaded Lottie, if present.
  Future<File?> cachedLottieFile(TextTemplatePackItem item) async {
    final dir = await _cacheDir();
    final file = File(p.join(dir.path, '${item.id}.json'));
    if (await file.exists()) return file;
    return null;
  }

  /// Prefer bundled asset, then cached download.
  Future<({String? asset, File? file})> resolveLottieSource(
    TextTemplatePackItem item,
  ) async {
    if (item.lottieAsset != null && item.lottieAsset!.isNotEmpty) {
      return (asset: item.lottieAsset, file: null);
    }
    final cached = await cachedLottieFile(item);
    return (asset: null, file: cached);
  }

  Future<void> install(TextTemplatePackItem item) async {
    if (isInstalled(item) || _downloading.contains(item.id)) return;
    if (item.lottieUrl == null || item.lottieUrl!.isEmpty) {
      await _markInstalled(item.id);
      return;
    }

    _downloading.add(item.id);
    notifyListeners();
    try {
      final uri = _resolveUrl(item.lottieUrl!);
      final response = await _http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('pack_download_failed:${response.statusCode}');
      }

      final dir = await _cacheDir();
      final file = File(p.join(dir.path, '${item.id}.json'));
      await file.writeAsBytes(response.bodyBytes, flush: true);
      await _markInstalled(item.id);
    } finally {
      _downloading.remove(item.id);
      notifyListeners();
    }
  }

  Future<TextTemplatePackCatalog> _loadBundledCatalog() async {
    final raw = await rootBundle.loadString(bundledCatalogAsset);
    return TextTemplatePackCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<TextTemplatePackCatalog> _fetchRemoteCatalog(String baseUrl) async {
    final uri = Uri.parse(
      baseUrl.endsWith('.json')
          ? baseUrl
          : '${baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'}catalog.json',
    );
    final response = await _http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('catalog_fetch_failed:${response.statusCode}');
    }
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
    if (catalog.baseUrl.isEmpty) {
      final root = baseUrl.endsWith('.json')
          ? baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1)
          : (baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
      return TextTemplatePackCatalog(
        version: catalog.version,
        baseUrl: root,
        categories: catalog.categories,
      );
    }
    return catalog;
  }

  TextTemplatePackCatalog _mergeCatalogs(
    TextTemplatePackCatalog bundled,
    TextTemplatePackCatalog remote,
  ) {
    final seen = <String>{};
    final categories = <TextTemplatePackCategory>[];

    void addCategory(TextTemplatePackCategory category) {
      final items = <TextTemplatePackItem>[];
      for (final item in category.items) {
        if (seen.add(item.id)) items.add(item);
      }
      if (items.isNotEmpty) {
        categories.add(
          TextTemplatePackCategory(
            id: category.id,
            title: category.title,
            items: items,
          ),
        );
      }
    }

    // Bundled first so local style/FX upgrades win over a stale CDN catalog.
    for (final category in bundled.categories) {
      addCategory(category);
    }
    for (final category in remote.categories) {
      addCategory(category);
    }

    return TextTemplatePackCatalog(
      version: remote.version >= bundled.version ? remote.version : bundled.version,
      baseUrl: remote.baseUrl.isNotEmpty ? remote.baseUrl : bundled.baseUrl,
      categories: categories,
    );
  }

  Uri _resolveUrl(String pathOrUrl) {
    final parsed = Uri.parse(pathOrUrl);
    if (parsed.hasScheme) return parsed;
    final base = _remoteBaseUrl.isNotEmpty
        ? _remoteBaseUrl
        : _catalog.baseUrl;
    if (base.isEmpty) {
      throw StateError('pack_base_url_missing');
    }
    final root = base.endsWith('/') ? base : '$base/';
    return Uri.parse(root).resolve(pathOrUrl);
  }

  Future<Directory> _cacheDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'text_template_packs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _markInstalled(String id) async {
    _installed.add(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(installedKey, _installed.toList(growable: false));
    notifyListeners();
  }
}
