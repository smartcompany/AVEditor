import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';

/// A Pro-only catalog item used somewhere in a project.
class PremiumUse {
  const PremiumUse({
    required this.kind,
    required this.itemId,
    required this.title,
  });

  final PremiumUseKind kind;
  final String itemId;
  final String title;
}

enum PremiumUseKind { transition, text }

/// Looks up whether catalog ids are Pro-only. Injected so tests do not need
/// the catalog services.
class PremiumCatalog {
  const PremiumCatalog({
    required this.transitionTitleIfPremium,
    required this.textTitleIfPremium,
  });

  /// The service-backed catalog used by the app.
  factory PremiumCatalog.live() {
    return PremiumCatalog(
      transitionTitleIfPremium: (id) {
        final item = TransitionCatalogService.instance.itemById(id);
        return item != null && item.premium ? item.title : null;
      },
      textTitleIfPremium: (id) {
        final item = TextTemplatePackService.instance.itemById(id);
        return item != null && item.premium ? item.title : null;
      },
    );
  }

  /// Title when [id] is a premium transition, else null.
  final String? Function(String id) transitionTitleIfPremium;

  /// Title when [id] is a premium text look, else null.
  final String? Function(String id) textTitleIfPremium;
}

/// Every distinct Pro item the project uses (one entry per catalog id).
List<PremiumUse> premiumUsesIn(VideoProject project, PremiumCatalog catalog) {
  final uses = <String, PremiumUse>{};
  for (final segment in project.segments) {
    final transition = segment.transition;
    if (transition == null || transition.isNone) continue;
    final title = catalog.transitionTitleIfPremium(transition.id);
    if (title == null) continue;
    uses.putIfAbsent(
      'transition:${transition.id}',
      () => PremiumUse(
        kind: PremiumUseKind.transition,
        itemId: transition.id,
        title: title,
      ),
    );
  }
  for (final overlay in project.overlays) {
    for (final id in [overlay.packItemId, overlay.templateId]) {
      if (id == null) continue;
      final title = catalog.textTitleIfPremium(id);
      if (title == null) continue;
      uses.putIfAbsent(
        'text:$id',
        () => PremiumUse(kind: PremiumUseKind.text, itemId: id, title: title),
      );
    }
  }
  return uses.values.toList();
}

/// A copy of [project] with every Pro item removed: premium transitions
/// become plain cuts and premium text looks fall back to the basic style.
/// Text content, timing and placement are kept.
VideoProject withoutPremium(VideoProject project, PremiumCatalog catalog) {
  bool premiumText(String? id) =>
      id != null && catalog.textTitleIfPremium(id) != null;

  final segments = [
    for (final segment in project.segments)
      if (segment.transition != null &&
          !segment.transition!.isNone &&
          catalog.transitionTitleIfPremium(segment.transition!.id) != null)
        segment.copyWith(clearTransition: true)
      else
        segment.copyWith(),
  ];
  final overlays = [
    for (final overlay in project.overlays)
      if (premiumText(overlay.packItemId) || premiumText(overlay.templateId))
        overlay.copyWith(templateId: null, packItemId: null, animationId: null)
      else
        overlay,
  ];
  return project.copyWith(segments: segments, overlays: overlays);
}
