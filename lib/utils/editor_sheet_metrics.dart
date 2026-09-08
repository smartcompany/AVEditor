import 'package:flutter/material.dart';

/// Shared bottom-sheet heights for transition + text panels.
///
/// Three stages:
/// 1. [maxFraction] — 2/3 of the screen height
/// 2. [entryFraction] — leaves the 16:9 preview uncovered
/// 3. [minFraction] — dismiss
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
  double? snapHeight(
    double height, {
    required double maxAvailable,
    double velocity = 0,
  }) {
    final entry = entryHeight.clamp(0.0, maxAvailable);
    final maxH = maxHeight.clamp(entry, maxAvailable);
    final minH = minHeight.clamp(0.0, entry);

    if (velocity > 600 || height <= minH + 24) return null;
    if (velocity < -400) return maxH;
    if (velocity > 400) {
      return height < (entry + maxH) / 2 ? null : entry;
    }

    final midDismiss = (minH + entry) / 2;
    if (height < midDismiss) return null;

    final midExpand = (entry + maxH) / 2;
    return height >= midExpand ? maxH : entry;
  }
}
