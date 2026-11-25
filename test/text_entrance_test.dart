import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/services/text_pack_image_cache.dart';
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

    test('pop scales with bounce overshoot then settles', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.pop,
        bounce: 0.2,
        scaleFrom: 0.2,
      );
      final early = evaluateTextEntrance(
        animationId: TextEntranceIds.pop,
        animation: anim,
        text: 'POP',
        progress: 0.2,
      );
      expect(early.layerScale, lessThan(1.2));
      expect(early.layerOpacity, greaterThan(0));
      final done = evaluateTextEntrance(
        animationId: TextEntranceIds.pop,
        animation: anim,
        text: 'POP',
        progress: 1,
      );
      expect(done.layerScale, closeTo(1, 0.01));
    });

    test('focus blurs then clears', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.focus,
        scaleFrom: 0.8,
        blurFrom: 0.4,
      );
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.focus,
        animation: anim,
        text: 'NAME',
        progress: 0.4,
        fontSize: 50,
      );
      expect(mid.layerBlur, greaterThan(0));
      expect(mid.layerScale, lessThan(1));
      final done = evaluateTextEntrance(
        animationId: TextEntranceIds.focus,
        animation: anim,
        text: 'NAME',
        progress: 1,
        fontSize: 50,
      );
      expect(done.layerBlur, 0);
      expect(done.layerScale, 1);
    });

    test('staged reveals slots sequentially', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.staged,
        slotStagger: 0.9,
      );
      final early = evaluateTextEntrance(
        animationId: TextEntranceIds.staged,
        animation: anim,
        text: 'a\nb\nc',
        progress: 0.15,
        slotCount: 3,
      );
      expect(early.slotOpacity.length, 3);
      expect(early.slotOpacity[0], greaterThan(0));
      expect(early.slotOpacity[2], lessThan(early.slotOpacity[0]));
      final done = evaluateTextEntrance(
        animationId: TextEntranceIds.staged,
        animation: anim,
        text: 'a\nb\nc',
        progress: 1,
        slotCount: 3,
      );
      expect(done.slotOpacity.every((o) => o >= 0.999), isTrue);
    });

    test('glitch and neon expose channel / glow fields', () {
      final glitch = evaluateTextEntrance(
        animationId: TextEntranceIds.glitch,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.glitch,
          glitchAmp: 0.1,
        ),
        text: 'ERR',
        progress: 0.3,
        fontSize: 40,
      );
      expect(glitch.rgbOffset.abs(), greaterThan(0));
      final neon = evaluateTextEntrance(
        animationId: TextEntranceIds.neon,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.neon,
          neonFlicker: 0.4,
        ),
        text: 'OPEN',
        progress: 0.5,
      );
      expect(neon.glowPulse, greaterThan(0.2));
    });

    test('wave offsets glyphs with phase; karaoke advances highlight', () {
      final wave = evaluateTextEntrance(
        animationId: TextEntranceIds.wave,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.wave,
          kineticAmp: 0.4,
        ),
        text: 'WAVE',
        progress: 0.25,
        fontSize: 40,
      );
      expect(wave.perGlyph, isTrue);
      expect(wave.glyphs.any((g) => g.dy.abs() > 0.5), isTrue);

      final karaoke = evaluateTextEntrance(
        animationId: TextEntranceIds.karaoke,
        animation: const TextEntranceAnimation(id: TextEntranceIds.karaoke),
        text: 'sing',
        progress: 0.5,
      );
      expect(karaoke.perGlyph, isFalse);
      expect(karaoke.highlightProgress, greaterThan(0.2));
      expect(karaoke.highlightProgress, lessThan(0.9));
    });

    test('blur_slide and marquee use layer dx; dissolve scatters glyphs', () {
      final blur = evaluateTextEntrance(
        animationId: TextEntranceIds.blurSlide,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.blurSlide,
          scrollStartFactor: 3,
          blurFrom: 0.5,
        ),
        text: 'SLIDE',
        progress: 0.2,
        fontSize: 40,
      );
      expect(blur.layerDx.abs(), greaterThan(1));
      expect(blur.layerBlur, greaterThan(1));

      final marquee = evaluateTextEntrance(
        animationId: TextEntranceIds.marquee,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.marquee,
          scrollStartFactor: 4,
          scrollEndFactor: -4,
        ),
        text: 'NEWS',
        progress: 0.0,
        fontSize: 20,
      );
      expect(marquee.layerDx, closeTo(80, 0.1));

      final dissolve = evaluateTextEntrance(
        animationId: TextEntranceIds.dissolve,
        animation: const TextEntranceAnimation(
          id: TextEntranceIds.dissolve,
          kineticAmp: 0.6,
        ),
        text: 'GO',
        progress: 0.15,
        fontSize: 40,
      );
      expect(dissolve.perGlyph, isTrue);
      expect(dissolve.glyphs.any((g) => g.opacity < 1), isTrue);
    });

    test('typewriter cursor flag appears while typing', () {
      const anim = TextEntranceAnimation(
        id: TextEntranceIds.typewriter,
        cursor: true,
        cursorBlinkHz: 2,
      );
      final mid = evaluateTextEntrance(
        animationId: TextEntranceIds.typewriter,
        animation: anim,
        text: 'Hello',
        progress: 0.4,
      );
      expect(mid.perGlyph, isTrue);
      // Cursor may blink off; at least glyph reveal still works.
      expect(mid.glyphs.where((g) => g.isVisible), isNotEmpty);
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
    test('seed catalog packs include entrance animations', () {
      final raw =
          File('test/fixtures/text_packs_catalog.json').readAsStringSync();
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
      () {
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

    test('resolveOverlayAnimation prefers overlay override', () {
      final raw =
          File('test/fixtures/text_packs_catalog.json').readAsStringSync();
      TextTemplatePackService.instance.debugSetCatalogForTest(
        TextTemplatePackCatalog.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        ),
      );

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
        final raw =
            File('test/fixtures/text_packs_catalog.json').readAsStringSync();
        final catalog = TextTemplatePackCatalog.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        TextTemplatePackService.instance.debugSetCatalogForTest(catalog);
        final journalBg = catalog.itemById('pack_journal')!.style.lineBackground!;
        await TextPackImageCache.instance.warmKeys({
          if (journalBg.underlayAsset != null) journalBg.underlayAsset!,
          ...journalBg.underlayVariants,
          if (journalBg.grainAsset != null) journalBg.grainAsset!,
        });
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
      mirrorReflection: true,
      mirrorGapFactor: 0.22,
    );
    final restored = TextStyleTemplate.fromJson(original.toJson());
    expect(restored.preferredFontId, 'gaegu');
    expect(restored.mirrorReflection, isTrue);
    expect(restored.mirrorGapFactor, 0.22);
  });
}
