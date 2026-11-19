import 'package:aveditor/models/effect_access_tier.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';

/// A paid catalog item used in a project that may be locked for the user.
class PremiumUse {
  const PremiumUse({
    required this.kind,
    required this.itemId,
    required this.title,
    required this.accessTier,
  });

  final PremiumUseKind kind;
  final String itemId;
  final String title;
  final EffectAccessTier accessTier;
}

enum PremiumUseKind { transition, text }

/// Looks up catalog access tiers. Injected so tests do not need live catalogs.
class PremiumCatalog {
  const PremiumCatalog({
    required this.transitionAccess,
    required this.textAccess,
  });

  factory PremiumCatalog.live() {
    return PremiumCatalog(
      transitionAccess: (id) {
        final item = TransitionCatalogService.instance.itemById(id);
        if (item == null || !item.accessTier.isPaid) return null;
        return (title: item.title, tier: item.accessTier);
      },
      textAccess: (id) {
        final item = TextTemplatePackService.instance.itemById(id);
        if (item == null || !item.accessTier.isPaid) return null;
        return (title: item.title, tier: item.accessTier);
      },
    );
  }

  /// Paid transition metadata, or null when free / unknown.
  final ({String title, EffectAccessTier tier})? Function(String id)
      transitionAccess;

  /// Paid text-look metadata, or null when free / unknown.
  final ({String title, EffectAccessTier tier})? Function(String id)
      textAccess;
}

/// Every distinct paid item the project uses (one entry per catalog id).
List<PremiumUse> premiumUsesIn(VideoProject project, PremiumCatalog catalog) {
  final uses = <String, PremiumUse>{};
  for (final segment in project.segments) {
    final transition = segment.transition;
    if (transition == null || transition.isNone) continue;
    final hit = catalog.transitionAccess(transition.id);
    if (hit == null) continue;
    uses.putIfAbsent(
      'transition:${transition.id}',
      () => PremiumUse(
        kind: PremiumUseKind.transition,
        itemId: transition.id,
        title: hit.title,
        accessTier: hit.tier,
      ),
    );
  }
  for (final overlay in project.overlays) {
    for (final id in [overlay.packItemId, overlay.templateId]) {
      if (id == null) continue;
      final hit = catalog.textAccess(id);
      if (hit == null) continue;
      uses.putIfAbsent(
        'text:$id',
        () => PremiumUse(
          kind: PremiumUseKind.text,
          itemId: id,
          title: hit.title,
          accessTier: hit.tier,
        ),
      );
    }
  }
  return uses.values.toList();
}

/// Paid items the user's plan does not cover (effects never cost credits).
///
/// [isAdUnlocked] skips items already unlocked by watching an ad.
List<PremiumUse> lockedUsesIn(
  VideoProject project,
  PremiumCatalog catalog,
  PlanTier userTier, {
  bool Function(PremiumUse use)? isAdUnlocked,
}) {
  return [
    for (final use in premiumUsesIn(project, catalog))
      if (!planCoversEffect(userTier, use.accessTier) &&
          !(isAdUnlocked?.call(use) ?? false))
        use,
  ];
}

/// Removes items above [userTier] that are not ad-unlocked: Plus/Pro
/// transitions become cuts; paid text looks fall back to the basic style.
/// Content and timing stay.
VideoProject withoutLocked(
  VideoProject project,
  PremiumCatalog catalog,
  PlanTier userTier, {
  bool Function(PremiumUse use)? isAdUnlocked,
}) {
  bool lockedText(String? id) {
    if (id == null) return false;
    final hit = catalog.textAccess(id);
    if (hit == null) return false;
    if (planCoversEffect(userTier, hit.tier)) return false;
    final use = PremiumUse(
      kind: PremiumUseKind.text,
      itemId: id,
      title: hit.title,
      accessTier: hit.tier,
    );
    return !(isAdUnlocked?.call(use) ?? false);
  }

  bool lockedTransition(String id) {
    final hit = catalog.transitionAccess(id);
    if (hit == null) return false;
    if (planCoversEffect(userTier, hit.tier)) return false;
    final use = PremiumUse(
      kind: PremiumUseKind.transition,
      itemId: id,
      title: hit.title,
      accessTier: hit.tier,
    );
    return !(isAdUnlocked?.call(use) ?? false);
  }

  final segments = [
    for (final segment in project.segments)
      if (segment.transition != null &&
          !segment.transition!.isNone &&
          lockedTransition(segment.transition!.id))
        segment.copyWith(clearTransition: true)
      else
        segment.copyWith(),
  ];
  final overlays = [
    for (final overlay in project.overlays)
      if (lockedText(overlay.packItemId) || lockedText(overlay.templateId))
        overlay.copyWith(templateId: null, packItemId: null, animationId: null)
      else
        overlay,
  ];
  return project.copyWith(segments: segments, overlays: overlays);
}

/// @Deprecated Prefer [withoutLocked] with the user's plan.
VideoProject withoutPremium(VideoProject project, PremiumCatalog catalog) =>
    withoutLocked(project, catalog, PlanTier.free);
