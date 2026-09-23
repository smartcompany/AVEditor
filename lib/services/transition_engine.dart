import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:flutter/foundation.dart';

/// How the editor should approximate a transition in the live preview.
enum TransitionPreviewKind {
  /// Hard cut — seek only.
  none,

  /// Dual-player compositor (opacity / slide / wipe / zoom approximations).
  dualLayer,
}

/// Shared plan produced once, then consumed by preview + export.
@immutable
class TransitionRenderPlan {
  const TransitionRenderPlan({
    required this.applied,
    required this.definition,
    required this.renderer,
    required this.effectName,
    required this.previewKind,
    required this.supportedInExport,
    this.fallbackReason,
  });

  final AppliedTransition applied;
  final TransitionItem? definition;
  final TransitionRendererKind renderer;

  /// Native / export effect id when [supportedInExport] is true.
  final String? effectName;
  final TransitionPreviewKind previewKind;
  final bool supportedInExport;
  final String? fallbackReason;

  Duration get duration => applied.duration;
}

/// Resolves catalog definitions into a single render plan for preview + export.
///
/// Renderers are hybrid: primitive/shader/custom may soft-bridge to a named
/// effect until a full GPU path exists — but the decision always goes through
/// this engine so preview and export cannot diverge silently.
class TransitionEngine {
  TransitionEngine({TransitionCatalogService? catalog})
      : _catalog = catalog ?? TransitionCatalogService.instance;

  static final TransitionEngine instance = TransitionEngine();

  final TransitionCatalogService _catalog;

  TransitionRenderPlan plan(AppliedTransition? applied) {
    if (applied == null || applied.isNone) {
      return TransitionRenderPlan(
        applied: AppliedTransition.none,
        definition: null,
        renderer: TransitionRendererKind.cut,
        effectName: null,
        previewKind: TransitionPreviewKind.none,
        supportedInExport: false,
      );
    }

    final definition = _catalog.catalog.byIdVersion(applied.id, applied.version);
    final renderer = definition?.renderer ?? TransitionRendererKind.xfade;

    switch (renderer) {
      case TransitionRendererKind.cut:
        return TransitionRenderPlan(
          applied: applied,
          definition: definition,
          renderer: renderer,
          effectName: null,
          previewKind: TransitionPreviewKind.none,
          supportedInExport: false,
        );
      case TransitionRendererKind.xfade:
        return _xfadePlan(applied, definition);
      case TransitionRendererKind.primitive:
        return _primitivePlan(applied, definition);
      case TransitionRendererKind.custom:
        return _customPlan(applied, definition);
      case TransitionRendererKind.shader:
      case TransitionRendererKind.asset:
        return _hybridSoftFail(applied, definition, renderer);
    }
  }

  /// Convenience for legacy call sites that only have an id string.
  TransitionRenderPlan planForId(String? transitionId, {Duration? duration}) {
    final migrated = migrateLegacyTransitionId(transitionId);
    if (migrated == null || migrated == 'none') {
      return plan(null);
    }
    final definition = _catalog.itemById(migrated);
    return plan(
      AppliedTransition(
        id: migrated,
        version: definition?.itemVersion ?? 1,
        duration: duration ??
            Duration(milliseconds: definition?.defaultDurationMs ?? 500),
        parameters: definition?.defaultParameters() ?? const {},
      ),
    );
  }

  String? effectNameFor(AppliedTransition? applied) {
    final resolved = plan(applied);
    if (!resolved.supportedInExport) return null;
    return resolved.effectName;
  }

  TransitionRenderPlan _xfadePlan(
    AppliedTransition applied,
    TransitionItem? definition,
  ) {
    final name = (definition?.effectName.isNotEmpty == true)
        ? definition!.effectName
        : applied.id;
    return TransitionRenderPlan(
      applied: applied,
      definition: definition,
      renderer: TransitionRendererKind.xfade,
      effectName: name,
      previewKind: _previewForEffect(name),
      supportedInExport: true,
    );
  }

  TransitionRenderPlan _primitivePlan(
    AppliedTransition applied,
    TransitionItem? definition,
  ) {
    // Prefer an explicit export bridge when the author provided one.
    if (definition != null && definition.effectName.isNotEmpty) {
      return TransitionRenderPlan(
        applied: applied,
        definition: definition,
        renderer: TransitionRendererKind.primitive,
        effectName: definition.effectName,
        previewKind: _previewForEffect(definition.effectName),
        supportedInExport: true,
        fallbackReason: 'primitive_bridged_to_xfade',
      );
    }

    final inferred = _inferEffectFromLayers(definition?.layers ?? const []);
    if (inferred != null) {
      return TransitionRenderPlan(
        applied: applied,
        definition: definition,
        renderer: TransitionRendererKind.primitive,
        effectName: inferred,
        previewKind: _previewForEffect(inferred),
        supportedInExport: true,
        fallbackReason: 'primitive_inferred_xfade',
      );
    }

    debugPrint(
      'TransitionEngine: primitive "${applied.id}" has no export bridge; '
      'falling back to fade',
    );
    return TransitionRenderPlan(
      applied: applied,
      definition: definition,
      renderer: TransitionRendererKind.primitive,
      effectName: 'fade',
      previewKind: TransitionPreviewKind.dualLayer,
      supportedInExport: true,
      fallbackReason: 'primitive_soft_fail_fade',
    );
  }

  /// Server-driven role compositors (`effect.kind` / customId) — preview is
  /// fully implemented; [effectName] is only the export bridge.
  TransitionRenderPlan _customPlan(
    AppliedTransition applied,
    TransitionItem? definition,
  ) {
    final role = TransitionRoleEffect.resolve(definition);
    final bridge = definition?.effectName;
    final name = (bridge != null && bridge.isNotEmpty) ? bridge : 'fade';

    if (role != null) {
      return TransitionRenderPlan(
        applied: applied,
        definition: definition,
        renderer: TransitionRendererKind.custom,
        effectName: name,
        previewKind: TransitionPreviewKind.dualLayer,
        supportedInExport: true,
        fallbackReason: bridge != null && bridge.isNotEmpty
            ? 'custom_export_bridge'
            : 'custom_export_bridge_fade',
      );
    }

    return _hybridSoftFail(applied, definition, TransitionRendererKind.custom);
  }

  TransitionRenderPlan _hybridSoftFail(
    AppliedTransition applied,
    TransitionItem? definition,
    TransitionRendererKind renderer,
  ) {
    final bridge = definition?.effectName;
    final name = (bridge != null && bridge.isNotEmpty) ? bridge : 'fade';
    debugPrint(
      'TransitionEngine: $renderer "${applied.id}" is not fully implemented; '
      'bridging to effect=$name',
    );
    return TransitionRenderPlan(
      applied: applied,
      definition: definition,
      renderer: renderer,
      effectName: name,
      previewKind: TransitionPreviewKind.dualLayer,
      supportedInExport: true,
      fallbackReason: '${renderer.name}_soft_fail',
    );
  }

  TransitionPreviewKind _previewForEffect(String name) {
    if (name.isEmpty) return TransitionPreviewKind.none;
    // Any named effect gets a dual-player approximation in the editor.
    return TransitionPreviewKind.dualLayer;
  }

  String? _inferEffectFromLayers(List<TransitionLayer> layers) {
    if (layers.isEmpty) return null;
    final props = layers.map((l) => l.property).toSet();
    if (props.length == 1 && props.single == TransitionProperty.opacity) {
      return 'fade';
    }
    if (props.contains(TransitionProperty.scale) &&
        props.contains(TransitionProperty.blur)) {
      return 'zoomin';
    }
    if (props.contains(TransitionProperty.scale)) {
      return 'zoomin';
    }
    if (props.contains(TransitionProperty.translateX)) {
      final layer = layers.firstWhere(
        (l) => l.property == TransitionProperty.translateX,
      );
      return layer.to < layer.from ? 'slideleft' : 'slideright';
    }
    if (props.contains(TransitionProperty.translateY)) {
      final layer = layers.firstWhere(
        (l) => l.property == TransitionProperty.translateY,
      );
      return layer.to < layer.from ? 'slideup' : 'slidedown';
    }
    if (props.contains(TransitionProperty.brightness)) {
      return 'fadewhite';
    }
    return null;
  }
}
