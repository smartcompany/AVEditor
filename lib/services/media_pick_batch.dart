import 'package:flutter/foundation.dart';

/// One picked media file ready for [ProjectStorageService] import.
@immutable
class MediaPickItem {
  const MediaPickItem({
    required this.path,
    this.libraryAssetId,
    this.duration,
    this.copyIntoProject = true,
  });

  /// Local file path that exists for this session (Photos export, camera, etc.).
  final String path;

  /// Durable Photos / MediaStore id from `photo_manager` ([AssetEntity.id]).
  ///
  /// When set with [copyIntoProject] false, the project stores a reference
  /// instead of copying bytes into Documents.
  final String? libraryAssetId;

  /// Known duration from the library (skips ffprobe when non-null and > 0).
  final Duration? duration;

  /// When true (default), copy into `media/<id>.ext`. Gallery library picks
  /// set this false for CapCut-style open-by-reference.
  final bool copyIntoProject;
}

/// Items ready to [ProjectStorageService.createFromImports] / [appendImports].
@immutable
class MediaPickBatch {
  const MediaPickBatch({
    required this.items,
    this.imageHoldDuration,
  });

  /// Convenience for camera / file picks that always copy into the project.
  factory MediaPickBatch.paths(
    List<String> paths, {
    Duration? imageHoldDuration,
  }) {
    return MediaPickBatch(
      items: [
        for (final path in paths)
          if (path.trim().isNotEmpty) MediaPickItem(path: path.trim()),
      ],
      imageHoldDuration: imageHoldDuration,
    );
  }

  final List<MediaPickItem> items;
  final Duration? imageHoldDuration;

  List<String> get paths => [for (final item in items) item.path];

  bool get isEmpty => items.isEmpty;
}
