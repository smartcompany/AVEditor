import 'dart:io';

import 'package:aveditor/utils/av_editor_log.dart';
import 'package:photo_manager/photo_manager.dart';

/// Resolves a Photos / MediaStore library id to a playable local file path.
///
/// CapCut-style imports keep [libraryAssetId] as the durable key and only ask
/// the OS for a session file URL when needed — no Documents byte copy.
class LibraryMediaResolver {
  const LibraryMediaResolver();

  /// Returns a readable file path, or null when the asset is gone / unavailable.
  Future<String?> resolve(String libraryAssetId) async {
    final id = libraryAssetId.trim();
    if (id.isEmpty) return null;

    try {
      final entity = await AssetEntity.fromId(id);
      if (entity == null) {
        avEditorLog('library resolve missing id=$id');
        return null;
      }

      // Prefer the locally available playable representation. Requesting the
      // original often forces a full export (slow for long 4K clips).
      final file = await entity.file;
      if (file != null &&
          await file.exists() &&
          await file.length() > 0) {
        return file.path;
      }

      final origin = await entity.originFile;
      if (origin != null &&
          await origin.exists() &&
          await origin.length() > 0) {
        return origin.path;
      }

      avEditorLog('library resolve empty file id=$id');
      return null;
    } catch (error, stack) {
      avEditorLog('library resolve failed id=$id: $error\n$stack');
      return null;
    }
  }
}
