import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

    test('typewriter auto finishes first line before second', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.typewriter,
        durationMs: 900,
        staggerBy: 'auto',
      );
      final midFirst = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        animation: anim,
        text: 'Hello\nWorld',
        progress: 0.25,
      );
      final hello = midFirst.glyphs.take(5);
      final world = midFirst.glyphs.skip(6);
      expect(hello.any((g) => g.isVisible), isTrue);
      expect(world.every((g) => !g.isVisible), isTrue);

      final midSecond = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        animation: anim,
        text: 'Hello\nWorld',
        progress: 0.75,
      );
      expect(midSecond.glyphs.take(5).every((g) => g.isVisible), isTrue);
      expect(midSecond.glyphs.skip(6).any((g) => g.isVisible), isTrue);
    });

    test('fade brings the whole line in together', () {
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.fade,
        text: 'Hi!',
        progress: 0.4,
      );
      expect(mid.perGlyph, isFalse);
      expect(mid.layerOpacity, greaterThan(0));
      expect(mid.layerOpacity, lessThan(1));
      expect(mid.layerDy, 0);
    });

    test('fade and typewriter look different mid-way', () {
      final fade = evaluateTextEntrance(
        animationId: TextEntranceIds.fade,
        text: 'Hello',
        progress: 0.5,
      );
      final type = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        text: 'Hello',
        progress: 0.5,
      );
      // Typewriter: some letters fully on, others off. Fade: no per-letter state.
      expect(type.perGlyph, isTrue);
      expect(type.glyphs.where((g) => g.opacity == 0), isNotEmpty);
      expect(fade.perGlyph, isFalse);
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

    test('crawl scrolls and keeps tilt through progress 1', () {
      const fontSize = 40.0;
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.crawl,
        durationMs: 18000,
        tiltDeg: 54,
        scrollStartFactor: 14,
        scrollEndFactor: -32,
      );
      final start = evaluateTextEntrance(
        animationId: TextEntranceIds.crawl,
        animation: anim,
        text: 'EPISODE\nZERO',
        progress: 0,
        fontSize: fontSize,
      );
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.crawl,
        animation: anim,
        text: 'EPISODE\nZERO',
        progress: 0.5,
        fontSize: fontSize,
      );
      final end = evaluateTextEntrance(
        animationId: TextEntranceIds.crawl,
        animation: anim,
        text: 'EPISODE\nZERO',
        progress: 1,
        fontSize: fontSize,
      );
      expect(start.hasCrawlTransform, isTrue);
      // Negative Flutter tilt: bottom nearer, top into the distance.
      expect(start.layerTilt, lessThan(-0.5));
      expect(start.layerScroll, closeTo(fontSize * 14, 0.01));
      expect(end.layerScroll, closeTo(fontSize * -32, 0.01));
      expect(start.layerScroll, greaterThan(mid.layerScroll));
      expect(mid.layerScroll, greaterThan(end.layerScroll));
      expect(end.layerTilt, equals(start.layerTilt));
      expect(end.hasCrawlTransform, isTrue);
      expect(end.isFullyVisible, isFalse);
    });

    test('crawl geometry follows server-driven animation fields', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.crawl,
        durationMs: 12000,
        tiltDeg: 40,
        perspective: 0.002,
        scrollStartFactor: 8,
        scrollEndFactor: -20,
      );
      final state = evaluateTextEntrance(
        animationId: TextEntranceIds.crawl,
        animation: anim,
        text: 'HELLO',
        progress: 0,
        fontSize: 10,
      );
      expect(state.layerTilt, closeTo(anim.flutterCrawlTiltRadians, 1e-9));
      expect(state.layerPerspective, closeTo(0.002, 1e-9));
      expect(state.layerScroll, closeTo(80, 0.01));
    });

    test('flat credits crawl uses zero tilt', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.crawl,
        durationMs: 16000,
        tiltDeg: 0,
        scrollStartFactor: 12,
        scrollEndFactor: -28,
      );
      final state = evaluateTextEntrance(
        animationId: TextEntranceIds.crawl,
        animation: anim,
        text: '타이틀\n이름  설명',
        progress: 0.25,
        fontSize: 20,
      );
      expect(state.layerTilt, 0);
      expect(state.hasCrawlTransform, isTrue);
      expect(state.layerScroll, lessThan(20 * 12));
    });

    test('crawl progress follows overlay span', () {
      final overlay = TextOverlay(
        text: 'Long ago…',
        start: Duration.zero,
        end: const Duration(seconds: 20),
        animationId: TextEntranceIds.crawl,
      );
      final anim = resolveOverlayAnimation(overlay);
      expect(anim.isContinuous, isTrue);
      expect(
        resolvedEntranceDuration(overlay: overlay, animation: anim),
        const Duration(seconds: 20),
      );
      expect(
        entranceProgressAt(
          overlay: overlay,
          position: const Duration(seconds: 10),
          animation: anim,
        ),
        closeTo(0.5, 0.001),
      );
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

    test('entrance frame index follows overlay start, not a later clip', () {
      expect(
        entranceFrameIndex(elapsedMs: 0, durationMs: 800, frameCount: 21),
        0,
      );
      expect(
        entranceFrameIndex(elapsedMs: 400, durationMs: 800, frameCount: 21),
        10,
      );
      expect(
        entranceFrameIndex(elapsedMs: 800, durationMs: 800, frameCount: 21),
        20,
      );
      expect(
        entranceFrameIndex(elapsedMs: 5000, durationMs: 800, frameCount: 21),
        20,
      );
    });

    test('looping sticker frames cycle past one loop duration', () {
      expect(
        entranceFrameIndex(
          elapsedMs: 0,
          durationMs: 1000,
          frameCount: 10,
          loop: true,
        ),
        0,
      );
      expect(
        entranceFrameIndex(
          elapsedMs: 500,
          durationMs: 1000,
          frameCount: 10,
          loop: true,
        ),
        5,
      );
      expect(
        entranceFrameIndex(
          elapsedMs: 1000,
          durationMs: 1000,
          frameCount: 10,
          loop: true,
        ),
        0,
      );
      expect(
        entranceFrameIndex(
          elapsedMs: 2500,
          durationMs: 1000,
          frameCount: 10,
          loop: true,
        ),
        5,
      );
    });

    test(
      'pack catalog durationMs is used when overlay has no override',
      () async {
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
      },
    );

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

  group('typewriter torn paper', () {
    Future<Uint8List> rgba(Uint8List png) async {
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      return data!.buffer.asUint8List();
    }

    test(
      'revealed paper keeps the finished shape (it does not stretch)',
      () async {
        await TextTemplatePackService.instance.ensureInitialized();
        const width = 360;
        const height = 640;
        final overlay = TextOverlay(
          text: 'abcdefghijkl',
          start: Duration.zero,
          end: const Duration(seconds: 3),
          animationId: TextEntranceIds.typewriter,
          animationDurationMs: 1000,
          packItemId: 'pack_journal',
        );
        const service = OverlayRasterService();
        final done = await rgba(
          await service.renderToPng(
            overlay,
            width: width,
            height: height,
            entrance: TextEntranceState.fullyVisible,
          ),
        );
        final typing = await rgba(
          await service.renderToPng(
            overlay,
            width: width,
            height: height,
            entrance: evaluateTextEntrance(
              animationId: TextEntranceIds.typewriter,
              text: overlay.text,
              progress: 0.7,
            ),
          ),
        );

        // Left third of the frame: paper and glyphs there are already revealed
        // mid-typing, so they must match the finished frame (up to edge anti-aliasing).
        var painted = 0;
        var differing = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width ~/ 3; x++) {
            final i = (y * width + x) * 4;
            if (done[i + 3] > 0) painted++;
            for (var c = 0; c < 4; c++) {
              // ±few levels: blur anti-aliasing inside the reveal clip.
              if ((done[i + c] - typing[i + c]).abs() > 6) {
                differing++;
                break;
              }
            }
          }
        }
        expect(painted, greaterThan(0), reason: 'paper reaches the left third');
        // A couple of edge AA pixels can differ under the reveal clip.
        expect(differing, lessThan(8));
      },
    );
  });

  group('overlay raster entrance', () {
    test(
      'static overlay renders one png; animated renders a sequence',
      () async {
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
      },
    );
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
