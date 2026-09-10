import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/foundation.dart';

/// Built-in entrance motion ids the client knows how to paint/export.
abstract final class TextEntranceIds {
  static const typewriter = 'typewriter';
  static const fade = 'fade';
  static const slideUp = 'slide_up';

  static const all = [typewriter, fade, slideUp];

  static bool isKnown(String? id) =>
      id != null && id.isNotEmpty && all.contains(id);
}

/// Pack / overlay entrance descriptor (server-driven).
@immutable
class TextEntranceAnimation {
  const TextEntranceAnimation({
    required this.id,
    this.durationMs = defaultDurationMs,
  });

  static const defaultDurationMs = 800;

  final String id;
  final int durationMs;

  Duration get duration => Duration(milliseconds: durationMs.clamp(100, 10000));

  bool get isNone => id.isEmpty || !TextEntranceIds.isKnown(id);

  Map<String, dynamic> toJson() => {
    'id': id,
    'durationMs': durationMs,
  };

  factory TextEntranceAnimation.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const TextEntranceAnimation(id: '');
    }
    return TextEntranceAnimation(
      id: json['id'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? defaultDurationMs,
    );
  }

  static const none = TextEntranceAnimation(id: '');
}

/// Resolves overlay override → pack default → none.
TextEntranceAnimation resolveOverlayAnimation(TextOverlay overlay) {
  final overrideId = overlay.animationId;
  if (overrideId != null) {
    if (overrideId.isEmpty) return TextEntranceAnimation.none;
    return TextEntranceAnimation(
      id: overrideId,
      durationMs:
          overlay.animationDurationMs ?? TextEntranceAnimation.defaultDurationMs,
    );
  }

  final pack = TextTemplatePackService.instance.itemById(overlay.packItemId);
  final packAnim = pack?.animation;
  if (packAnim != null && !packAnim.isNone) {
    return TextEntranceAnimation(
      id: packAnim.id,
      durationMs:
          overlay.animationDurationMs ?? packAnim.durationMs,
    );
  }

  return TextEntranceAnimation.none;
}

/// How long the entrance plays before the finished look holds.
///
/// Uses pack/catalog [TextEntranceAnimation.durationMs] (or an explicit
/// overlay override). The rest of the overlay clip stays fully revealed.
Duration resolvedEntranceDuration({
  required TextOverlay overlay,
  required TextEntranceAnimation animation,
}) {
  if (animation.isNone) return Duration.zero;
  final overrideMs = overlay.animationDurationMs;
  if (overrideMs != null) {
    return Duration(milliseconds: overrideMs.clamp(100, 30000));
  }
  return Duration(milliseconds: animation.durationMs.clamp(100, 30000));
}

/// Progress 0..1 from playhead relative to overlay start.
///
/// Clamps at 1 so the finished style holds for the remainder of the clip.
double entranceProgressAt({
  required TextOverlay overlay,
  required Duration position,
  required TextEntranceAnimation animation,
}) {
  if (animation.isNone) return 1;
  if (position < overlay.start) return 0;
  final elapsed = position - overlay.start;
  final totalMs =
      resolvedEntranceDuration(overlay: overlay, animation: animation)
          .inMilliseconds;
  if (totalMs <= 0) return 1;
  return (elapsed.inMilliseconds / totalMs).clamp(0.0, 1.0);
}
