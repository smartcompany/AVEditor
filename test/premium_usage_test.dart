import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/effect_access_tier.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const catalog = PremiumCatalog(
    transitionAccess: _transitionAccess,
    textAccess: _textAccess,
  );

  VideoProject buildProject() => VideoProject(
    id: 'p',
    sourcePath: '/tmp/s.mp4',
    duration: const Duration(seconds: 9),
    segments: [
      ClipSegment(
        id: 'a',
        start: Duration.zero,
        end: const Duration(seconds: 3),
        transition: const AppliedTransition(
          id: 'cube',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      ),
      ClipSegment(
        id: 'b',
        start: const Duration(seconds: 3),
        end: const Duration(seconds: 6),
        transition: const AppliedTransition(
          id: 'dissolve',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      ),
      ClipSegment(
        id: 'c',
        start: const Duration(seconds: 6),
        end: const Duration(seconds: 9),
        transition: const AppliedTransition(
          id: 'swap',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      ),
    ],
    overlays: [
      TextOverlay(
        id: 't1',
        text: 'neon',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        packItemId: 'pack_neon_pink',
        animationId: 'fade',
      ),
      TextOverlay(
        id: 't2',
        text: 'plain',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        packItemId: 'effect_outline',
      ),
    ],
  );

  test('lists each paid item once with access tier', () {
    final uses = premiumUsesIn(buildProject(), catalog);
    expect(
      uses.map((u) => u.itemId),
      unorderedEquals(['cube', 'swap', 'pack_neon_pink']),
    );
    expect(
      uses.firstWhere((u) => u.itemId == 'cube').accessTier,
      EffectAccessTier.pro,
    );
    expect(
      uses.firstWhere((u) => u.itemId == 'swap').accessTier,
      EffectAccessTier.plus,
    );
  });

  test('Plus unlocks Plus effects but not Pro', () {
    final locked = lockedUsesIn(buildProject(), catalog, PlanTier.plus);
    expect(
      locked.map((u) => u.itemId),
      unorderedEquals(['cube', 'pack_neon_pink']),
    );
  });

  test('Pro unlocks Plus and Pro effects', () {
    expect(lockedUsesIn(buildProject(), catalog, PlanTier.pro), isEmpty);
    expect(lockedUsesIn(buildProject(), catalog, PlanTier.studio), isEmpty);
  });

  test('stripping for free removes all paid items', () {
    final project = buildProject();
    final stripped = withoutLocked(project, catalog, PlanTier.free);

    expect(stripped.segments[0].transition, isNull);
    expect(stripped.segments[1].transition?.id, 'dissolve');
    expect(stripped.segments[2].transition, isNull);

    final neon = stripped.overlays.firstWhere((o) => o.id == 't1');
    expect(neon.packItemId, isNull);
    expect(neon.animationId, isNull);
    expect(neon.text, 'neon');
    expect(
      stripped.overlays.firstWhere((o) => o.id == 't2').packItemId,
      'effect_outline',
    );

    expect(project.segments[0].transition?.id, 'cube');
    expect(project.overlays.first.packItemId, 'pack_neon_pink');
  });

  test('stripping for Plus keeps Plus effects', () {
    final stripped = withoutLocked(buildProject(), catalog, PlanTier.plus);
    expect(stripped.segments[0].transition, isNull); // cube = Pro
    expect(stripped.segments[2].transition?.id, 'swap'); // Plus
    expect(
      stripped.overlays.firstWhere((o) => o.id == 't1').packItemId,
      isNull,
    );
  });
}

({String title, EffectAccessTier tier})? _transitionAccess(String id) {
  return switch (id) {
    'cube' => (title: 'Cube', tier: EffectAccessTier.pro),
    'swap' => (title: 'Swap', tier: EffectAccessTier.plus),
    _ => null,
  };
}

({String title, EffectAccessTier tier})? _textAccess(String id) {
  return switch (id) {
    'pack_neon_pink' => (title: 'Neon Pink', tier: EffectAccessTier.pro),
    _ => null,
  };
}
