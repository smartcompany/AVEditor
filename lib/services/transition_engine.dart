import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
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
    required this.xfadeName,
    required this.previewKind,
    required this.supportedInExport,
    this.fallbackReason,
  });

  final AppliedTransition applied;
  final TransitionItem? definition;
  final TransitionRendererKind renderer;

  /// FFmpeg `xfade` transition name when [supportedInExport] is true.
  final String? xfadeName;
  final TransitionPreviewKind previewKind;
  final bool supportedInExport;
  final String? fallbackReason;

  Duration get duration => applied.duration;
}

/// Resolves catalog definitions into a single render plan for preview + export.
///
/// Renderers are hybrid: primitive/shader/custom may soft-bridge to xfade until
/// a full GPU / filter-graph path exists — but the decision always goes through
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
        xfadeName: null,
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
          xfadeName: null,
          previewKind: TransitionPreviewKind.none,
          supportedInExport: false,
        );
      case TransitionRendererKind.xfade:
        return _xfadePlan(applied, definition);
      case TransitionRendererKind.primitive:
        return _primitivePlan(applied, definition);
      case TransitionRendererKind.shader:
      case TransitionRendererKind.custom:
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

  String? ffmpegNameFor(AppliedTransition? applied) {
    final resolved = plan(applied);
    if (!resolved.supportedInExport) return null;
    return resolved.xfadeName;
  }

  TransitionRenderPlan _xfadePlan(
    AppliedTransition applied,
    TransitionItem? definition,
  ) {
    final name = (definition?.ffmpegName.isNotEmpty == true)
        ? definition!.ffmpegName
        : applied.id;
    return TransitionRenderPlan(
      applied: applied,
      definition: definition,
      renderer: TransitionRendererKind.xfade,
      xfadeName: name,
      previewKind: _previewForXfade(name),
      supportedInExport: true,
    );
  }

  TransitionRenderPlan _primitivePlan(
    AppliedTransition applied,
    TransitionItem? definition,
  ) {
    // Prefer an explicit export bridge when the author provided one.
    if (definition != null && definition.ffmpegName.isNotEmpty) {
      return TransitionRenderPlan(
        applied: applied,
        definition: definition,
        renderer: TransitionRendererKind.primitive,
        xfadeName: definition.ffmpegName,
        previewKind: _previewForXfade(definition.ffmpegName),
        supportedInExport: true,
        fallbackReason: 'primitive_bridged_to_xfade',
      );
    }

    final inferred = _inferXfadeFromLayers(definition?.layers ?? const []);
    if (inferred != null) {
      return TransitionRenderPlan(
        applied: applied,
        definition: definition,
        renderer: TransitionRendererKind.primitive,
        xfadeName: inferred,
        previewKind: _previewForXfade(inferred),
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
      xfadeName: 'fade',
      previewKind: TransitionPreviewKind.dualLayer,
      supportedInExport: true,
      fallbackReason: 'primitive_soft_fail_fade',
    );
  }

  TransitionRenderPlan _hybridSoftFail(
    AppliedTransition applied,
    TransitionItem? definition,
    TransitionRendererKind renderer,
  ) {
    final bridge = definition?.ffmpegName;
    final name = (bridge != null && bridge.isNotEmpty) ? bridge : 'fade';
    debugPrint(
      'TransitionEngine: $renderer "${applied.id}" is not fully implemented; '
      'bridging to xfade=$name',
    );
    return TransitionRenderPlan(
      applied: applied,
      definition: definition,
      renderer: renderer,
      xfadeName: name,
      previewKind: TransitionPreviewKind.dualLayer,
      supportedInExport: true,
      fallbackReason: '${renderer.name}_soft_fail',
    );
  }

  TransitionPreviewKind _previewForXfade(String name) {
    if (name.isEmpty) return TransitionPreviewKind.none;
    // Any named xfade gets a dual-player approximation in the editor.
    return TransitionPreviewKind.dualLayer;
  }

  String? _inferXfadeFromLayers(List<TransitionLayer> layers) {
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
