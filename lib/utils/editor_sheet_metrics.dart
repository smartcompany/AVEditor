import 'package:flutter/material.dart';

/// Shared bottom-dock / sheet heights for the editor.
///
/// Three stages (absolute heights):
/// 1. [maxHeight] — panel = 2/3 screen → video area ≈ 1/3
/// 2. [entryHeight] — normal panel / timeline view
/// 3. `0` — full video (panel hidden)
class EditorSheetMetrics {
  const EditorSheetMetrics({
    required this.entryFraction,
    required this.maxFraction,
    required this.minFraction,
    required this.screenHeight,
  });

  final double entryFraction;
  final double maxFraction;
  final double minFraction;
  final double screenHeight;

  double get entryHeight => screenHeight * entryFraction;
  double get maxHeight => screenHeight * maxFraction;
  double get minHeight => screenHeight * minFraction;

  /// Absolute ceiling used only for clamping — interactive max is [_maxFractionValue].
  static const _maxFractionValue = 2 / 3;
  static const minFractionValue = 0.12;

  static EditorSheetMetrics of(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final contentW = media.size.width - 24;
    final videoH = contentW * 16 / 9;
    final reservedTop = (media.padding.top + kToolbarHeight + 8 + videoH)
        .clamp(screenH * 0.32, screenH * 0.58);
    final entry = ((screenH - reservedTop) / screenH).clamp(0.28, 0.48);
    // Max is 2/3 screen; keep entry strictly below max so snaps stay distinct.
    final maxFrac = _maxFractionValue;
    final entryFrac = entry < maxFrac - 0.04 ? entry : maxFrac - 0.04;
    return EditorSheetMetrics(
      entryFraction: entryFrac,
      maxFraction: maxFrac,
      minFraction: minFractionValue,
      screenHeight: screenH,
    );
  }

  /// Snap [height] to entry or max, or `null` when the sheet should dismiss.
  ///
  /// Dismiss is only allowed from the **entry** stage (or below). A fling
  /// down from max always settles on entry first so the panel cannot vanish
  /// in one gesture from the tallest height.
  double? snapHeight(
    double height, {
    required double maxAvailable,
    double velocity = 0,
  }) {
    final entry = entryHeight.clamp(0.0, maxAvailable);
    final maxH = maxHeight.clamp(entry, maxAvailable);
    final minH = minHeight.clamp(0.0, entry);
    final midExpand = (entry + maxH) / 2;

    // Above entry: only entry ↔ max. Never dismiss from the tall stage.
    if (height > entry + 8) {
      if (velocity < -400) return maxH;
      if (velocity > 400) return entry;
      return height >= midExpand ? maxH : entry;
    }

    // At / below entry: entry or dismiss.
    if (velocity < -400) return maxH;
    if (velocity > 500 || height <= minH + 24) return null;

    final midDismiss = (minH + entry) / 2;
    if (height < midDismiss) return null;
    return entry;
  }
}

/// Dock stops in pixels: hidden → panel (entry) → panel at 2/3 screen.
List<double> dockHeightStops({
  required double entryHeight,
  required double maxHeight,
}) {
  final entry = entryHeight.clamp(0.0, maxHeight);
  final maxH = maxHeight < entry ? entry : maxHeight;
  if ((maxH - entry).abs() < 24) {
    return [0.0, maxH];
  }
  return [0.0, entry, maxH];
}

/// Snap dock height to the nearest (or fling-adjacent) stop.
///
/// [velocity] uses Flutter's vertical convention: positive = finger down
/// (collapse / grow video), negative = finger up (expand panel). Flings move
/// one stop at a time: max(2/3) → entry → hidden (and the reverse).
double snapDockHeight({
  required double current,
  required double velocity,
  required List<double> stops,
  double flingVelocity = 320,
}) {
  assert(stops.isNotEmpty);
  final sorted = List<double>.from(stops)..sort();
  if (velocity.abs() > flingVelocity) {
    if (velocity < 0) {
      return sorted.firstWhere(
        (s) => s > current + 8,
        orElse: () => sorted.last,
      );
    }
    return sorted.lastWhere(
      (s) => s < current - 8,
      orElse: () => sorted.first,
    );
  }
  return sorted.reduce(
    (a, b) => (current - a).abs() <= (current - b).abs() ? a : b,
  );
}
