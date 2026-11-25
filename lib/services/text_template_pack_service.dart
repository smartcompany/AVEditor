import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_pack_image_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Server-driven Word Art catalog.
///
/// Flow:
/// 1. Show disk cache immediately (if any).
/// 2. Always fetch remote catalog.
/// 3. If remote [version] differs from disk cache → replace + save disk.
/// No bundled catalog — offline with empty disk shows an empty grid.
class TextTemplatePackService extends ChangeNotifier {
  TextTemplatePackService({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static const remoteBaseUrlKey = 'text_template_pack_base_url';
  static const installedKey = 'text_template_pack_installed';
  static const _diskCatalogFile = 'catalog.json';

  /// Production pack API on Vercel.
  static const defaultRemoteBaseUrl = 'https://aveditorserver.vercel.app/';

  static final TextTemplatePackService instance = TextTemplatePackService();

  final http.Client _http;

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
      await run.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      debugPrint('TextTemplatePackService: init timed out');
      _lastError = 'timeout';
      _ready = true;
      notifyListeners();
    } catch (error) {
      debugPrint('TextTemplatePackService: init failed: $error');
      _ready = true;
      notifyListeners();
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

  /// Test-only: install a catalog without hitting the network or disk.
  @visibleForTesting
  void debugSetCatalogForTest(TextTemplatePackCatalog catalog) {
    _catalog = catalog;
    _ready = true;
    _lastError = null;
    _syncing = false;
  }

  /// Panel open: show disk cache, then always fetch remote and replace when
  /// the remote catalog [version] differs from the disk cache version.
  Future<void> syncOnPanelOpen() async {
    await ensureInitialized();
    final base = _resolvedBaseUrl();
    if (base.isEmpty) return;

    final existing = _syncFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final run = _fetchAndApplyRemote(base, showSyncing: true);
    _syncFuture = run;
    try {
      await run;
    } finally {
      if (identical(_syncFuture, run)) _syncFuture = null;
    }
  }

  /// Show disk cache first, then fetch remote (awaited or background).
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

    final disk = await _loadDiskCatalog();
    if (disk != null && disk.allItems.isNotEmpty) {
      _catalog = disk;
      _ready = true;
      notifyListeners();
      unawaited(_warmUnderlayImages(disk));
      debugPrint(
        'TextTemplatePackService: disk cache '
        'v${disk.version}/${disk.allItems.length}',
      );
    }

    final base = _resolvedBaseUrl();
    if (base.isEmpty) {
      _ready = true;
      notifyListeners();
      return;
    }

    if (awaitRemote || !hasItems) {
      if (!hasItems) {
        _syncing = true;
        notifyListeners();
      }
      try {
        await _fetchAndApplyRemote(base, showSyncing: false);
      } finally {
        if (_syncing) {
          _syncing = false;
        }
      }
      _ready = true;
      notifyListeners();
    } else {
      _ready = true;
      notifyListeners();
      unawaited(_fetchAndApplyRemote(base, showSyncing: true));
    }
  }

  Future<void> _fetchAndApplyRemote(
    String base, {
    required bool showSyncing,
  }) async {
    try {
      final fetched = await _fetchRemoteCatalog(base);
      final remote = fetched.catalog;
      if (remote.allItems.isEmpty) return;

      final diskVersion = (await _loadDiskCatalog())?.version;
      final localVersion = diskVersion ?? _catalog.version;
      debugPrint(
        'TextTemplatePackService: remote v${remote.version}/'
        '${remote.allItems.length} vs disk v$localVersion/'
        '${_catalog.allItems.length}',
      );

      if (remote.version == localVersion && hasItems) {
        return;
      }

      if (showSyncing) {
        _syncing = true;
        notifyListeners();
      }
      try {
        _catalog = remote;
        _ready = true;
        notifyListeners();
        await _saveDiskCatalogBytes(fetched.rawBytes);
        await _warmUnderlayImages(remote);
        debugPrint(
          'TextTemplatePackService: applied remote '
          'v${remote.version}/${remote.allItems.length}',
        );
      } finally {
        if (showSyncing) {
          _syncing = false;
          notifyListeners();
        }
      }
    } catch (error) {
      _lastError = error.toString();
      debugPrint('TextTemplatePackService: remote fetch failed: $error');
      if (_syncing) {
        _syncing = false;
        notifyListeners();
      }
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
    await refresh(awaitRemote: true);
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

  String _resolvedBaseUrl() {
    final trimmed = _remoteBaseUrl.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return defaultRemoteBaseUrl;
  }

  String _normalizedRoot(String baseUrl) {
    if (baseUrl.endsWith('.json')) {
      return baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1);
    }
    return baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  }

  Future<File> _diskCatalogFileHandle() async {
    final dir = await _cacheDir();
    return File(p.join(dir.path, _diskCatalogFile));
  }

  Future<TextTemplatePackCatalog?> _loadDiskCatalog() async {
    try {
      final file = await _diskCatalogFileHandle();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      var catalog = TextTemplatePackCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (catalog.allItems.isEmpty) return null;
      if (catalog.baseUrl.isEmpty) {
        catalog = TextTemplatePackCatalog(
          version: catalog.version,
          baseUrl: _normalizedRoot(_resolvedBaseUrl()),
          categories: catalog.categories,
        );
      }
      return catalog;
    } catch (error) {
      debugPrint('TextTemplatePackService: disk read failed: $error');
      return null;
    }
  }

  Future<void> _saveDiskCatalogBytes(List<int> bytes) async {
    try {
      final file = await _diskCatalogFileHandle();
      await file.writeAsBytes(bytes, flush: true);
    } catch (error) {
      debugPrint('TextTemplatePackService: disk write failed: $error');
    }
  }

  Future<({TextTemplatePackCatalog catalog, List<int> rawBytes})>
  _fetchRemoteCatalog(String baseUrl) async {
    final root = _normalizedRoot(baseUrl);
    final uri = Uri.parse('${root}catalog.json').replace(
      queryParameters: {'cb': '${DateTime.now().millisecondsSinceEpoch}'},
    );
    final response = await _http
        .get(
          uri,
          headers: const {
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('catalog_fetch_failed:${response.statusCode}');
    }
    final rawBytes = response.bodyBytes;
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>,
    );
    if (catalog.baseUrl.isEmpty) {
      return (
        catalog: TextTemplatePackCatalog(
          version: catalog.version,
          baseUrl: root,
          categories: catalog.categories,
        ),
        rawBytes: rawBytes,
      );
    }
    return (catalog: catalog, rawBytes: rawBytes);
  }

  Uri _resolveUrl(String pathOrUrl) {
    final parsed = Uri.parse(pathOrUrl);
    if (parsed.hasScheme) return parsed;
    final base = _remoteBaseUrl.isNotEmpty ? _remoteBaseUrl : _catalog.baseUrl;
    if (base.isEmpty) {
      throw StateError('pack_base_url_missing');
    }
    return Uri.parse(_normalizedRoot(base)).resolve(pathOrUrl);
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
