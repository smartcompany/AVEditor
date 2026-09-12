import 'package:aveditor/models/transition_item.dart';

/// Project-local transition instance. Pins catalog [id] + [version] so server
/// catalog updates do not silently change already-edited projects.
class AppliedTransition {
  const AppliedTransition({
    required this.id,
    required this.version,
    required this.duration,
    this.parameters = const {},
  });

  final String id;
  final int version;
  final Duration duration;
  final Map<String, double> parameters;

  static const none = AppliedTransition(
    id: 'none',
    version: 1,
    duration: Duration.zero,
  );

  bool get isNone {
    final trimmed = id.trim();
    return trimmed.isEmpty || trimmed == 'none';
  }

  AppliedTransition copyWith({
    String? id,
    int? version,
    Duration? duration,
    Map<String, double>? parameters,
  }) {
    return AppliedTransition(
      id: id ?? this.id,
      version: version ?? this.version,
      duration: duration ?? this.duration,
      parameters: parameters ?? this.parameters,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'version': version,
        'durationMs': duration.inMilliseconds,
        if (parameters.isNotEmpty) 'parameters': parameters,
      };

  factory AppliedTransition.fromJson(Map<String, dynamic> json) {
    final paramsRaw = json['parameters'];
    final parameters = <String, double>{};
    if (paramsRaw is Map) {
      for (final entry in paramsRaw.entries) {
        final value = entry.value;
        if (value is num) parameters[entry.key.toString()] = value.toDouble();
      }
    }

    final durationMs = (json['durationMs'] as num?)?.toInt() ??
        (((json['duration'] as num?)?.toDouble() ?? 0.5) * 1000).round();

    return AppliedTransition(
      id: json['id'] as String? ?? 'none',
      version: (json['version'] as num?)?.toInt() ?? 1,
      duration: Duration(milliseconds: durationMs),
      parameters: parameters,
    );
  }

  /// Builds an applied instance from a catalog definition + optional overrides.
  factory AppliedTransition.fromDefinition(
    TransitionItem definition, {
    Duration? duration,
    Map<String, double>? parameters,
  }) {
    return AppliedTransition(
      id: definition.id,
      version: definition.itemVersion,
      duration: duration ?? Duration(milliseconds: definition.defaultDurationMs),
      parameters: {
        ...definition.defaultParameters(),
        ...?parameters,
      },
    );
  }

  /// Migrates legacy flat `transitionId` / `transitionMs` project fields.
  factory AppliedTransition.fromLegacy({
    required String? transitionId,
    required int? transitionMs,
  }) {
    final id = migrateLegacyTransitionId(transitionId);
    if (id == null || id == 'none') return AppliedTransition.none;
    return AppliedTransition(
      id: id,
      version: 1,
      duration: Duration(
        milliseconds: transitionMs ?? 500,
      ),
    );
  }
}

/// Maps older catalog ids onto the v3 definition ids when names changed.
String? migrateLegacyTransitionId(String? raw) {
  final id = raw?.trim() ?? '';
  if (id.isEmpty) return null;
  const aliases = <String, String>{
    // Keep stable ids; only remap known renames here.
    'cross_dissolve': 'dissolve',
    'dip_to_black': 'fadeblack',
    'dip_to_white': 'fadewhite',
    'zoom_in': 'zoomin',
    'zoom_out': 'zoomout',
    'cross_zoom': 'crosszoom',
    'cursor_zoom': 'cursorzoom',
    'cross_blur': 'crossblur',
    'circle_open': 'circleopen',
    'circle_close': 'circleclose',
    'page_curl': 'pagecurl',
    'spin_in': 'spinin',
    'spin_out': 'spinout',
    'slide_left': 'slideleft',
    'slide_right': 'slideright',
    'slide_up': 'slideup',
    'slide_down': 'slidedown',
    'push_left': 'pushleft',
    'push_right': 'pushright',
    'push_up': 'pushup',
    'push_down': 'pushdown',
    'wipe_left': 'wipeleft',
    'wipe_right': 'wiperight',
    'wipe_up': 'wipeup',
    'wipe_down': 'wipedown',
  };
  return aliases[id] ?? id;
}
