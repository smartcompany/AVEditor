import 'package:aveditor/models/transition_item.dart';
import 'package:flutter/foundation.dart';

/// Built-in role compositor kinds the client knows how to paint.
///
/// The server picks one via `effect.kind` (or legacy `customId`). Catalog
/// item **ids** are never consulted — rename/id-swap on the server must not
/// break clients.
///
/// Wipe is a [TransitionProperty.wipe] layer, not a role kind.
abstract final class TransitionRoleKinds {
  static const doorway = 'doorway';
  static const puzzle = 'puzzle';

  static const all = [doorway, puzzle];

  static bool isKnown(String? kind) =>
      kind != null && kind.isNotEmpty && all.contains(kind);
}

/// Resolved server-driven role compositor for dual-clip special layouts.
@immutable
class TransitionRoleEffect {
  const TransitionRoleEffect({
    required this.kind,
    this.params = const {},
  });

  final String kind;
  final Map<String, dynamic> params;

  bool get isDoorway => kind == TransitionRoleKinds.doorway;
  bool get isPuzzle => kind == TransitionRoleKinds.puzzle;

  /// Incoming scale at t=0 for doorway (defaults match iMovie).
  double get incomingScaleFrom =>
      (params['incomingScaleFrom'] as num?)?.toDouble() ?? 0.84;

  /// Incoming scale at t=1 for doorway.
  double get incomingScaleTo =>
      (params['incomingScaleTo'] as num?)?.toDouble() ?? 1.0;

  /// Puzzle strip enter direction (right-puzzle when true).
  bool get reverse => params['reverse'] == true;

  /// Resolve from catalog definition. Never uses [TransitionItem.id].
  static TransitionRoleEffect? resolve(TransitionItem? definition) {
    if (definition == null) return null;

    final effect = definition.effect;
    final rawKind = _nonEmpty(effect?['kind'] as String?) ??
        _nonEmpty(definition.customId);
    if (rawKind == null) return null;

    final kind = _normalizeKind(rawKind);
    if (!TransitionRoleKinds.isKnown(kind)) return null;

    final params = <String, dynamic>{
      ...?effect,
      // Legacy customIds encode puzzle direction when effect.reverse is absent.
      if (kind == TransitionRoleKinds.puzzle &&
          effect?['reverse'] == null &&
          rawKind == 'puzzleright')
        'reverse': true,
      if (kind == TransitionRoleKinds.puzzle &&
          effect?['reverse'] == null &&
          rawKind == 'puzzleleft')
        'reverse': false,
    };
    params.remove('kind');

    return TransitionRoleEffect(kind: kind, params: Map.unmodifiable(params));
  }

  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Map legacy plugin ids onto canonical kinds.
  static String _normalizeKind(String raw) {
    switch (raw) {
      case 'puzzleleft':
      case 'puzzleright':
        return TransitionRoleKinds.puzzle;
      default:
        return raw;
    }
  }
}

extension TransitionItemRoleEffect on TransitionItem {
  TransitionRoleEffect? get roleEffect => TransitionRoleEffect.resolve(this);

  bool get hasRoleCompositor => roleEffect != null;
}
