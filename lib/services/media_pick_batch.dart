import 'package:flutter/foundation.dart';

/// Paths ready to [ProjectStorageService.appendImports], with optional still hold.
@immutable
class MediaPickBatch {
  const MediaPickBatch({
    required this.paths,
    this.imageHoldDuration,
  });

  final List<String> paths;
  final Duration? imageHoldDuration;

  bool get isEmpty => paths.isEmpty;
}
