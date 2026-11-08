import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/models/clip_segment.dart';
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
/// A split only adds a cut marker. Adjacent pieces with no transition and no
/// gap still show the same frames, so this key stays the same and the player
/// is left alone. Rebuilding it flashed black, then stopped on the new clip
/// boundary.
String timelineCompositionSignature(List<ClipSegment> segments) {
  final parts = <String>[];
  var rangeStartMs = -1;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (rangeStartMs < 0) rangeStartMs = segment.start.inMilliseconds;
    final next = i + 1 < segments.length ? segments[i + 1] : null;
    final hardJoin =
        next != null && segment.end == next.start && !segment.hasTransition;
    if (hardJoin) continue;
    final transition = segment.hasTransition
        ? '${segment.transitionId}-${segment.transitionDuration.inMilliseconds}'
        : 'cut';
    parts.add('$rangeStartMs-${segment.end.inMilliseconds}-$transition');
    rangeStartMs = -1;
  }
  return parts.join('|');
}

/// Transition description shared by timeline playback and album export.
///
/// iOS and Android native engines both receive this map. They may draw it
/// with different renderers, but they do not build a second transition plan.
List<Map<String, dynamic>> encodeCompositionSegments(List<ClipSegment> segments) {
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
    encoded.add({
      'startMs': segment.start.inMilliseconds,
      'endMs': segment.end.inMilliseconds,
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
