import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/widgets/transition_layer_runtime.dart';

/// Native compositor / GPU effect id (slideleft, dissolve, …).
String compositionEffectName(AppliedTransition? applied) {
  final name = TransitionEngine.instance.effectNameFor(applied);
  if (name == null || name.isEmpty) return 'fade';
  return name;
}

/// Catalog motion replayed by timeline playback and album export.
///
/// `param` endpoints are resolved here (catalog defaults, then the user's
/// values) so iOS and Android draw the same strength the Flutter preview does.
List<Map<String, Object>> compositionMotion(AppliedTransition? applied) {
  final definition = TransitionEngine.instance.plan(applied).definition;
  final layers = definition?.layers ?? const [];
  final parameters = <String, double>{
    ...?definition?.defaultParameters(),
    ...?applied?.parameters,
  };
  return [
    for (final layer in layers)
      {
        'property': layer.property.name,
        'from': resolveTransitionLayerEndpoint(layer.from, layer, parameters),
        'to': resolveTransitionLayerEndpoint(layer.to, layer, parameters),
        'easing': layer.easing.name,
        'target': layer.target.toJson(),
        'start': layer.start,
        'end': layer.end,
        if (layer.mode != null) 'mode': layer.mode!,
        // Ripple bend strength (catalog `intensity`, default 0.7). Native
        // renderers ignored it before, so the slider did nothing in the app.
        if (layer.property == TransitionProperty.ripple)
          'amount': parameters['intensity'] ?? 0.7,
        if (layer.grid != null)
          'grid': {
            'columns': layer.grid!.columns,
            'rows': layer.grid!.rows,
            'gap': layer.grid!.gap,
            'stagger': layer.grid!.stagger,
          },
      },
  ];
}

/// Identity of the frames the native preview actually draws.
///
/// Never hard-joins across different [ClipSegment.mediaId]s.
String timelineCompositionSignature(List<ClipSegment> segments) {
  final parts = <String>[];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final next = i + 1 < segments.length ? segments[i + 1] : null;
    final sameMedia = next != null &&
        segment.mediaId == next.mediaId &&
        segment.end == next.start &&
        !segment.hasTransition;
    if (sameMedia) {
      // Coalesce contiguous pieces of the same asset until a cut/transition.
      continue;
    }
    // Walk back to the start of this same-media hard-joined run.
    var rangeStart = segment.start.inMilliseconds;
    var j = i;
    while (j > 0) {
      final prev = segments[j - 1];
      final cur = segments[j];
      if (prev.mediaId != cur.mediaId ||
          prev.end != cur.start ||
          prev.hasTransition) {
        break;
      }
      rangeStart = prev.start.inMilliseconds;
      j--;
    }
    final transition = segment.hasTransition
        ? '${segment.transitionId}-${segment.transitionDuration.inMilliseconds}'
        : 'cut';
    parts.add(
      '${segment.mediaId ?? '_'}:$rangeStart-${segment.end.inMilliseconds}-$transition',
    );
  }
  return parts.join('|');
}

/// Transition description shared by timeline playback and album export.
///
/// Each segment includes its resolved [sourcePath] and media [kind].
List<Map<String, dynamic>> encodeCompositionSegments(
  List<ClipSegment> segments, {
  VideoProject? project,
  String? fallbackSourcePath,
}) {
  final encoded = <Map<String, dynamic>>[];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final next = i < segments.length - 1 ? segments[i + 1] : null;
    final td = next == null
        ? Duration.zero
        : clampedTransitionDuration(segment, next: next);
    final effect = segment.hasTransition && td > Duration.zero
        ? compositionEffectName(segment.transition)
        : null;
    final motion = segment.hasTransition && td > Duration.zero
        ? compositionMotion(segment.transition)
        : const <Map<String, Object>>[];
    final role = segment.hasTransition
        ? TransitionEngine.instance.plan(segment.transition).definition?.roleEffect
        : null;
    final asset = project?.assetById(segment.mediaId);
    final path = project?.pathForSegment(segment) ?? fallbackSourcePath;
    final kind = asset?.kind.name ?? MediaAssetKind.video.name;
    encoded.add({
      'startMs': segment.start.inMilliseconds,
      'endMs': segment.end.inMilliseconds,
      'durationMs': segment.duration.inMilliseconds,
      if (segment.mediaId != null) 'mediaId': segment.mediaId,
      if (path != null) 'sourcePath': path,
      'kind': kind,
      if (effect != null) ...{
        'transitionEffect': effect,
        'transitionDurationMs': td.inMilliseconds,
        if (motion.isNotEmpty) 'transitionLayers': motion,
        if (role != null) ...{
          'transitionKind': role.kind,
          'transitionReverse': role.reverse,
          'transitionParams': {
            for (final entry in role.params.entries)
              if (entry.value is num ||
                  entry.value is bool ||
                  entry.value is String)
                entry.key: entry.value,
          },
        },
      },
    });
  }
  return encoded;
}
