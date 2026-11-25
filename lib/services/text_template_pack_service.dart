import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_pack_image_cache.dart';
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
  var _syncing = false;
  String? _lastError;
  Future<void>? _initFuture;
  Future<void>? _syncFuture;

  TextTemplatePackCatalog get catalog => _catalog;
  bool get isReady => _ready;
  bool get isSyncing => _syncing;
  String? get lastError => _lastError;
  String get remoteBaseUrl => _remoteBaseUrl;
  bool get hasItems => _catalog.allItems.isNotEmpty;

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
      debugPrint('TextTemplatePackService: init timed out');
      _lastError = 'timeout';
      if (!hasItems) {
        await _loadBundledIntoState();
      } else if (!_ready) {
        _ready = true;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('TextTemplatePackService: init failed: $error');
      if (!hasItems) {
        await _loadBundledIntoState();
      }
    } finally {
      _initFuture = null;
    }
  }

  /// Force a reload (settings retry / after hot reload empty state).
  Future<void> reload() async {
    _ready = false;
    _initFuture = null;
    await refresh(awaitRemote: true);
  }

  /// Panel open: keep showing cache, silently fetch remote. Only when
  /// [version] differs set [isSyncing] and replace the catalog (loading bar).
  Future<void> syncOnPanelOpen() async {
    await ensureInitialized();
    final base = _remoteBaseUrl.trim().isNotEmpty
        ? _remoteBaseUrl.trim()
        : defaultRemoteBaseUrl;
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
      final remote = await _fetchRemoteCatalog(base);
      if (remote.allItems.isEmpty) return;
      if (remote.version == _catalog.version) return;

      // Newer catalog → loading bar while we swap (avoids a silent flash).
      _syncing = true;
      notifyListeners();
      try {
        _catalog = remote.baseUrl.isNotEmpty
            ? remote
            : TextTemplatePackCatalog(
                version: remote.version,
                baseUrl: _catalog.baseUrl,
                categories: remote.categories,
              );
        notifyListeners();
        await _warmUnderlayImages(_catalog);
      } finally {
        _syncing = false;
        notifyListeners();
      }
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TextTemplatePackService: panel sync failed: $error');
      if (_syncing) {
        _syncing = false;
        notifyListeners();
      }
    }
  }

  /// Load bundled immediately so the text studio is never blocked on network.
  /// Remote merges in the background unless [awaitRemote] is true.
  Future<void> refresh({bool awaitRemote = false}) async {
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
      final bundled = await _loadBundledCatalog().timeout(
        const Duration(seconds: 3),
      );
      _catalog = bundled;
      _ready = true;
      notifyListeners();
      unawaited(_warmUnderlayImages(bundled));

      final base = _remoteBaseUrl.trim();
      if (base.isEmpty) return;

      if (awaitRemote) {
        await _mergeRemote(base, bundled);
      } else {
        unawaited(_mergeRemote(base, bundled));
      }
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TextTemplatePackService: refresh failed: $error');
      await _loadBundledIntoState();
    }
  }

  Future<void> _loadBundledIntoState() async {
    try {
      final bundled = await _loadBundledCatalog().timeout(
        const Duration(seconds: 2),
      );
      _catalog = bundled;
      _ready = true;
      notifyListeners();
      unawaited(_warmUnderlayImages(bundled));
    } catch (bundledError) {
      debugPrint(
        'TextTemplatePackService: bundled load failed: $bundledError',
      );
      _lastError = bundledError.toString();
      // Keep any non-empty catalog already on screen.
      if (!hasItems) {
        _catalog = TextTemplatePackCatalog.empty();
      }
      _ready = true;
      notifyListeners();
    }
  }

  Future<void> _mergeRemote(String base, TextTemplatePackCatalog bundled) async {
    try {
      final remote = await _fetchRemoteCatalog(base);
      if (remote.allItems.isEmpty) return;
      if (remote.version == _catalog.version) return;
      final next = remote.baseUrl.isNotEmpty
          ? remote
          : TextTemplatePackCatalog(
              version: remote.version,
              baseUrl: bundled.baseUrl,
              categories: remote.categories,
            );
      _catalog = next;
      notifyListeners();
      unawaited(_warmUnderlayImages(next));
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TextTemplatePackService: remote merge failed: $error');
    }
  }

  Future<void> _warmUnderlayImages(TextTemplatePackCatalog catalog) async {
    final keys = <String>{};
    for (final item in catalog.allItems) {
      final bg = item.style.lineBackground;
      if (bg == null) continue;
      final asset = bg.underlayAsset?.trim();
      if (asset != null && asset.isNotEmpty) keys.add(asset);
      keys.addAll(bg.underlayVariants);
      final grain = bg.grainAsset?.trim();
      if (grain != null && grain.isNotEmpty) keys.add(grain);
    }
    if (keys.isEmpty) return;
    await TextPackImageCache.instance.warmKeys(keys);
    notifyListeners();
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
    final response = await _http
        .get(uri)
        .timeout(const Duration(seconds: 12));
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

  Uri _resolveUrl(String pathOrUrl) {
    final parsed = Uri.parse(pathOrUrl);
    if (parsed.hasScheme) return parsed;
    final base = _remoteBaseUrl.isNotEmpty ? _remoteBaseUrl : _catalog.baseUrl;
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
