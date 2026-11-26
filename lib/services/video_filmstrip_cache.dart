import 'dart:collection';

import 'package:aveditor/services/video_frame_grab.dart';
import 'package:flutter/foundation.dart';

/// In-memory JPEG stills shared by the share scrubber and YouTube thumbnail
/// strip so the same video is not decoded twice.
class VideoFilmstripCache {
  VideoFilmstripCache._();
  static final VideoFilmstripCache instance = VideoFilmstripCache._();

  static const _maxEntries = 160;
  static const _bucketMs = 100;

  /// Shared strip tile size so share scrubber ↔ YouTube editor hit the same keys.
  static const stripMaxHeight = 160;
  static const stripQuality = 70;

  final _bytes = LinkedHashMap<String, Uint8List>();
  final _grab = const VideoFrameGrab();

  @visibleForTesting
  void clear() => _bytes.clear();

  /// Round seek times so nearby scrubber / editor samples share a tile.
  static int bucketTimeMs(int timeMs) {
    if (timeMs <= 0) return 0;
    return ((timeMs + _bucketMs ~/ 2) ~/ _bucketMs) * _bucketMs;
  }

  static String cacheKey({
    required String video,
    required int timeMs,
    required int maxHeight,
    required int quality,
  }) {
    return '$video|${bucketTimeMs(timeMs)}|$maxHeight|$quality';
  }

  Uint8List? peek({
    required String video,
    required int timeMs,
    required int maxHeight,
    int quality = 70,
  }) {
    return _bytes[cacheKey(
      video: video,
      timeMs: timeMs,
      maxHeight: maxHeight,
      quality: quality,
    )];
  }

  Future<Uint8List?> getBytes({
    required String video,
    required int timeMs,
    int maxHeight = 160,
    int maxWidth = 0,
    int quality = 70,
    bool accurate = false,
  }) async {
    final key = cacheKey(
      video: video,
      timeMs: timeMs,
      maxHeight: maxHeight,
      quality: quality,
    );
    final hit = _bytes[key];
    if (hit != null) {
      // LRU: re-insert at end.
      _bytes.remove(key);
      _bytes[key] = hit;
      return hit;
    }

    final bytes = await _grab.jpegBytes(
      video: video,
      timeMs: bucketTimeMs(timeMs),
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      quality: quality,
      accurate: accurate,
    );
    if (bytes == null || bytes.isEmpty) return null;
    _remember(key, bytes);
    return bytes;
  }

  /// Load [timesMs] with limited parallelism; [onFrame] as each tile arrives.
  Future<List<Uint8List?>> loadTimes({
    required String video,
    required List<int> timesMs,
    required int maxHeight,
    int maxWidth = 0,
    int quality = 70,
    bool accurate = false,
    int concurrency = 4,
    void Function(int index, Uint8List bytes)? onFrame,
  }) async {
    if (timesMs.isEmpty) return const [];
    final out = List<Uint8List?>.filled(timesMs.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next;
        next += 1;
        if (i >= timesMs.length) return;
        final bytes = await getBytes(
          video: video,
          timeMs: timesMs[i],
          maxHeight: maxHeight,
          maxWidth: maxWidth,
          quality: quality,
          accurate: accurate,
        );
        if (bytes == null) continue;
        out[i] = bytes;
        onFrame?.call(i, bytes);
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, timesMs.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    return out;
  }

  void _remember(String key, Uint8List bytes) {
    _bytes[key] = bytes;
    while (_bytes.length > _maxEntries) {
      _bytes.remove(_bytes.keys.first);
    }
  }
}
