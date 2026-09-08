import 'dart:io';

import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Downloads and caches transition asset packages by id + itemVersion.
///
/// Custom effect rendering is out of scope; this store only ensures bytes are
/// on disk for a future engine.
class TransitionAssetStore extends ChangeNotifier {
  TransitionAssetStore({
    http.Client? httpClient,
    TransitionCatalogService? catalog,
  })  : _http = httpClient ?? http.Client(),
        _catalog = catalog ?? TransitionCatalogService.instance;

  static final TransitionAssetStore instance = TransitionAssetStore();

  final http.Client _http;
  final TransitionCatalogService _catalog;
  final Set<String> _downloading = {};
  final Set<String> _installedKeys = {};
  var _scanned = false;

  bool isDownloading(String id) => _downloading.contains(id);

  String cacheKey(TransitionItem item) => '${item.id}@v${item.itemVersion}';

  bool isInstalled(TransitionItem item) {
    if (!item.needsDownload) return true;
    return _installedKeys.contains(cacheKey(item));
  }

  Future<void> ensureScanned() async {
    if (_scanned) return;
    try {
      final root = await _transitionsRoot();
      if (!await root.exists()) {
        _scanned = true;
        return;
      }
      await for (final idEntity in root.list()) {
        if (idEntity is! Directory) continue;
        final id = p.basename(idEntity.path);
        await for (final verEntity in idEntity.list()) {
          if (verEntity is! Directory) continue;
          final name = p.basename(verEntity.path);
          if (!name.startsWith('v')) continue;
          final version = int.tryParse(name.substring(1));
          if (version == null) continue;
          final marker = File(p.join(verEntity.path, '.ready'));
          if (await marker.exists()) {
            _installedKeys.add('$id@v$version');
            continue;
          }
          await for (final _ in verEntity.list()) {
            _installedKeys.add('$id@v$version');
            break;
          }
        }
      }
    } catch (error) {
      debugPrint('TransitionAssetStore scan failed: $error');
    }
    _scanned = true;
    notifyListeners();
  }

  /// Local directory for [item], if present and marked ready.
  Future<Directory?> cachedDirectory(TransitionItem item) async {
    await ensureScanned();
    if (!isInstalled(item)) return null;
    final dir = await _itemDir(item);
    if (!await dir.exists()) return null;
    return dir;
  }

  /// Downloads [item.assetUrl] into `transitions/{id}/v{itemVersion}/`.
  Future<Directory> install(TransitionItem item) async {
    await ensureScanned();
    if (!item.needsDownload) {
      throw StateError('transition_asset_not_required:${item.id}');
    }
    if (_downloading.contains(item.id)) {
      throw StateError('transition_asset_busy:${item.id}');
    }

    final url = _catalog.resolvedAssetUrl(item);
    if (url == null || url.isEmpty) {
      throw StateError('transition_asset_url_missing:${item.id}');
    }

    _downloading.add(item.id);
    notifyListeners();
    try {
      final response =
          await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('transition_asset_download_failed:${response.statusCode}');
      }

      final dir = await _itemDir(item);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);

      // Store raw package bytes; future engine may unpack zip/etc.
      final package = File(p.join(dir.path, 'package.bin'));
      await package.writeAsBytes(response.bodyBytes, flush: true);
      await File(p.join(dir.path, '.ready')).writeAsString(
        '${item.itemVersion}',
        flush: true,
      );

      _installedKeys.add(cacheKey(item));
      return dir;
    } finally {
      _downloading.remove(item.id);
      notifyListeners();
    }
  }

  Future<Directory> _transitionsRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'transitions'));
  }

  Future<Directory> _itemDir(TransitionItem item) async {
    final root = await _transitionsRoot();
    return Directory(
      p.join(root.path, item.id, 'v${item.itemVersion}'),
    );
  }
}
