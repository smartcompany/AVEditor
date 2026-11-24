import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Decoded pack images (paper masks, grain) shared by preview + export paint.
class TextPackImageCache extends ChangeNotifier {
  TextPackImageCache._();
  static final TextPackImageCache instance = TextPackImageCache._();

  final Map<String, ui.Image> _images = {};
  final Map<String, Future<ui.Image?>> _inflight = {};

  ui.Image? operator [](String key) => _images[key];

  bool contains(String key) => _images.containsKey(key);

  /// Warm bundled / remote underlays referenced by the catalog.
  Future<void> warmKeys(Iterable<String> keys) async {
    await Future.wait(keys.map(ensure));
  }

  Future<ui.Image?> ensure(String key) {
    if (key.isEmpty) return Future.value(null);
    final hit = _images[key];
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(key, () => _load(key));
  }

  Future<ui.Image?> _load(String key) async {
    try {
      late final Uint8List bytes;
      if (key.startsWith('http://') || key.startsWith('https://')) {
        final res = await http.get(Uri.parse(key));
        if (res.statusCode < 200 || res.statusCode >= 300) return null;
        bytes = res.bodyBytes;
      } else if (key.startsWith('assets/')) {
        final data = await rootBundle.load(key);
        bytes = data.buffer.asUint8List();
      } else {
        // Relative pack path → bundled asset under text_packs/.
        final asset = key.startsWith('text_packs/')
            ? 'assets/$key'
            : 'assets/text_packs/$key';
        final data = await rootBundle.load(asset);
        bytes = data.buffer.asUint8List();
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _images[key] = frame.image;
      notifyListeners();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      _inflight.remove(key);
    }
  }
}
