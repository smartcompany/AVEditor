import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('evaluateTextEntrance', () {
    test('unknown id is fully visible', () {
      final state = evaluateTextEntrance(
        animationId: 'unknown_fx',
        text: 'Hi',
        progress: 0.3,
      );
      expect(state.isFullyVisible, isTrue);
    });

    test('typewriter reveals graphemes over progress', () {
      final early = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        text: 'ABCD',
        progress: 0.05,
      );
      expect(early.perGlyph, isTrue);
      expect(early.glyphs.where((g) => g.isVisible).length, lessThan(4));

      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        text: 'ABCD',
        progress: 0.5,
      );
      expect(mid.glyphs.where((g) => g.isVisible).length, greaterThan(0));

      final done = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        text: 'ABCD',
        progress: 1,
      );
      expect(done.isFullyVisible, isTrue);
    });

    test('fade staggers opacity', () {
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.fade,
        text: 'Hi!',
        progress: 0.4,
      );
      expect(mid.perGlyph, isTrue);
      expect(mid.glyphs.any((g) => g.opacity > 0 && g.opacity < 1), isTrue);
    });

    test('slide_up uses layer opacity and dy', () {
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.slideUp,
        text: 'Go',
        progress: 0.5,
        fontSize: 80,
      );
      expect(mid.perGlyph, isFalse);
      expect(mid.layerOpacity, greaterThan(0));
      expect(mid.layerOpacity, lessThan(1));
      expect(mid.layerDy, greaterThan(0));
    });
  });

  group('catalog animation', () {
    test('bundled packs include entrance animations', () async {
      final raw = await rootBundle.loadString('assets/text_packs/catalog.json');
      final catalog = TextTemplatePackCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      // Static text effects ship without entrance animation.
      expect(catalog.itemById('effect_pop_green')!.animation.isNone, isTrue);
      expect(catalog.itemById('effect_pastel')!.animation.isNone, isTrue);
      expect(catalog.itemById('effect_torn_label')!.animation.isNone, isTrue);
    });

    test('entrance uses fixed duration then holds for rest of clip', () {
      final overlay = TextOverlay(
        text: 'Hi',
        start: Duration.zero,
        end: const Duration(seconds: 10),
        animationId: TextEntranceIds.typewriter,
        animationDurationMs: 800,
      );
      final anim = resolveOverlayAnimation(overlay);
      expect(
        resolvedEntranceDuration(overlay: overlay, animation: anim),
        const Duration(milliseconds: 800),
      );
      expect(
        entranceProgressAt(
          overlay: overlay,
          position: const Duration(milliseconds: 400),
          animation: anim,
        ),
        closeTo(0.5, 0.001),
      );
      // Past entrance → fully revealed for the rest of the timeline.
      expect(
        entranceProgressAt(
          overlay: overlay,
          position: const Duration(seconds: 5),
          animation: anim,
        ),
        1.0,
      );
    });

    test('pack catalog durationMs is used when overlay has no override', () async {
      await TextTemplatePackService.instance.ensureInitialized();
      final overlay = TextOverlay(
        text: 'Hi',
        start: Duration.zero,
        end: const Duration(seconds: 10),
        animationId: TextEntranceIds.typewriter,
        animationDurationMs: 900,
      );
      final anim = resolveOverlayAnimation(overlay);
      expect(anim.id, 'typewriter');
      expect(
        resolvedEntranceDuration(overlay: overlay, animation: anim),
        const Duration(milliseconds: 900),
      );
    });

    test('resolveOverlayAnimation prefers overlay override', () async {
      final service = TextTemplatePackService();
      await service.ensureInitialized();
      // Warm singleton used by resolveOverlayAnimation.
      await TextTemplatePackService.instance.ensureInitialized();

      final fromPack = TextOverlay(
        text: 'hi',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        packItemId: 'effect_torn_label',
        animationId: TextEntranceIds.typewriter,
      );
      expect(resolveOverlayAnimation(fromPack).id, 'typewriter');

      final forcedNone = fromPack.copyWith(animationId: '');
      expect(resolveOverlayAnimation(forcedNone).isNone, isTrue);

      final forcedFade = fromPack.copyWith(animationId: TextEntranceIds.fade);
      expect(resolveOverlayAnimation(forcedFade).id, 'fade');
    });
  });

  group('overlay raster entrance', () {
    test('static overlay renders one png; animated renders a sequence', () async {
      final dir = await Directory.systemTemp.createTemp('aveditor_rast_');
      addTearDown(() => dir.delete(recursive: true));

      const service = OverlayRasterService();
      final staticOverlay = TextOverlay(
        text: 'Static',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        animationId: '',
      );
      final animated = TextOverlay(
        text: 'Hi',
        start: Duration.zero,
        end: const Duration(seconds: 2),
        animationId: TextEntranceIds.fade,
        animationDurationMs: 400,
      );

      final rasters = await service.renderAll(
        [staticOverlay, animated],
        width: 180,
        height: 320,
        outputDir: dir,
      );

      expect(rasters, hasLength(2));
      expect(rasters[0].isAnimated, isFalse);
      expect(rasters[0].file, isNotNull);
      expect(await rasters[0].file!.exists(), isTrue);

      expect(rasters[1].isAnimated, isTrue);
      expect(rasters[1].frameCount, greaterThan(2));
      final frames = rasters[1].sequenceDir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'));
      expect(frames.length, rasters[1].frameCount);
    });
  });

  test('TextStyleTemplate still round-trips', () {
    const original = TextStyleTemplate(
      id: 'x',
      label: 'X',
      preferredFontId: 'gaegu',
    );
    final restored = TextStyleTemplate.fromJson(original.toJson());
    expect(restored.preferredFontId, 'gaegu');
  });
}
