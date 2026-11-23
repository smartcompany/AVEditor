import 'dart:io';

import 'package:aveditor/services/giphy_service.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Downloads Giphy stickers into `media/stickers/` under the project folder.
class StickerStorageService {
  StickerStorageService({http.Client? client}) : _client = client;

  final http.Client? _client;

  /// Relative path under [projectDir], e.g. `media/stickers/<id>.gif`.
  static String relativePathFor(String fileName) =>
      p.join('media', 'stickers', fileName);

  static String absolutePath(String projectDir, String relativePath) =>
      p.join(projectDir, relativePath);

  Future<String> downloadGiphySticker({
    required String projectDir,
    required GiphySticker sticker,
  }) async {
    final uri = Uri.parse(sticker.downloadUrl);
    final response = await (_client ?? http.Client()).get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('sticker_download_failed:${response.statusCode}');
    }

    final safeId = sticker.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final fileName = '${safeId}_${const Uuid().v4().substring(0, 8)}.gif';
    final relative = relativePathFor(fileName);
    final dest = File(absolutePath(projectDir, relative));
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(response.bodyBytes, flush: true);
    return relative;
  }
}
