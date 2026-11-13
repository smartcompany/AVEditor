import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const catalog = PremiumCatalog(
    transitionTitleIfPremium: _premiumTransition,
    textTitleIfPremium: _premiumText,
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
          id: 'cube',
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

  test('lists each premium item once', () {
    final uses = premiumUsesIn(buildProject(), catalog);
    expect(
      uses.map((u) => u.itemId),
      unorderedEquals(['cube', 'pack_neon_pink']),
    );
    expect(
      uses.firstWhere((u) => u.itemId == 'cube').kind,
      PremiumUseKind.transition,
    );
  });

  test('a project with only free items needs nothing', () {
    final free = withoutPremium(buildProject(), catalog);
    expect(premiumUsesIn(free, catalog), isEmpty);
  });

  test('stripping keeps free items, text and timing; original untouched', () {
    final project = buildProject();
    final stripped = withoutPremium(project, catalog);

    expect(stripped.segments[0].transition, isNull);
    expect(stripped.segments[1].transition?.id, 'dissolve');
    expect(stripped.segments[2].transition, isNull);

    final neon = stripped.overlays.firstWhere((o) => o.id == 't1');
    expect(neon.packItemId, isNull);
    expect(neon.animationId, isNull);
    expect(neon.text, 'neon');
    expect(neon.end, const Duration(seconds: 2));
    expect(
      stripped.overlays.firstWhere((o) => o.id == 't2').packItemId,
      'effect_outline',
    );

    // The editor's own project keeps its Pro items.
    expect(project.segments[0].transition?.id, 'cube');
    expect(project.overlays.first.packItemId, 'pack_neon_pink');
  });
}

String? _premiumTransition(String id) => id == 'cube' ? 'Cube' : null;

String? _premiumText(String id) => id == 'pack_neon_pink' ? 'Neon Pink' : null;
