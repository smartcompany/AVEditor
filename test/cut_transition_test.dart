import 'dart:convert';

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cut transitions', () {
    test('nearestCutIndex picks closest packed cut', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 7),
        ),
        ClipSegment(
          start: const Duration(seconds: 7),
          end: const Duration(seconds: 10),
        ),
      ];

      expect(nearestCutIndex(segments, const Duration(seconds: 1)), 0);
      expect(nearestCutIndex(segments, const Duration(seconds: 4)), 0);
      expect(nearestCutIndex(segments, const Duration(seconds: 6)), 1);
    });

    test('exportTimelineDuration unchanged when transition applied', () {
      final without = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];
      final withFade = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      expect(totalKeptDuration(without), const Duration(seconds: 6));
      expect(exportTimelineDuration(without), const Duration(seconds: 6));
      // Duration-preserving: A+B (same as hard cut).
      expect(exportTimelineDuration(withFade), const Duration(seconds: 6));
      expect(
        totalTransitionOverlap(withFade),
        const Duration(milliseconds: 500),
      );
    });

    test('source↔export round trip with duration-preserving packing', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      expect(exportTimelineDuration(segments), const Duration(seconds: 6));

      const probes = [
        Duration.zero,
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 5),
        Duration(seconds: 6),
      ];
      for (final source in probes) {
        final export = sourceTimeToExportTime(
          segments,
          source,
          applyTransitions: true,
        )!;
        final back = exportTimeToSourceTime(
          segments,
          export,
          applyTransitions: true,
        );
        expect(back, source, reason: 'round trip at $source');
      }

      // Duration-preserving: source maps like a hard cut (no pull-back).
      expect(
        sourceTimeToExportTime(
          segments,
          const Duration(seconds: 4),
          applyTransitions: true,
        ),
        const Duration(seconds: 4),
      );
    });

    test('transitionSequenceSpan is centered on the cut', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      final span = transitionSequenceSpan(segments, 0)!;
      // td=500 → ⌊td/2⌋=250 before, 250 after → [2750, 3250)
      expect(span.start, const Duration(milliseconds: 2750));
      expect(span.end, const Duration(milliseconds: 3250));
      expect(
        span.end - span.start,
        const Duration(milliseconds: 500),
      );
    });

    test('previewFadeAt covers opacity-crossfade plans', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'fade',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      expect(previewFadeAt(segments, const Duration(seconds: 2)), isNull);
      expect(
        previewFadeAt(segments, const Duration(milliseconds: 2749)),
        isNull,
      );

      // Center of [2750, 3250) is the cut at 3000 → t=0.5.
      final mid = previewFadeAt(segments, const Duration(seconds: 3))!;
      expect(mid.afterIndex, 0);
      expect(mid.t, closeTo(0.5, 0.02));
      expect(mid.td, const Duration(milliseconds: 500));
      // Aux shows B[start, start+after) stretched: at t=0.5 → start+125.
      expect(mid.auxSourceTime, const Duration(milliseconds: 3125));
      expect(mid.outgoingSourceTime, const Duration(milliseconds: 2875));
      expect(mid.windowStart, const Duration(milliseconds: 2750));
      expect(mid.windowEnd, const Duration(milliseconds: 3250));

      // Exclusive end at cut + ⌈td/2⌉.
      expect(
        previewFadeAt(segments, const Duration(milliseconds: 3250)),
        isNull,
      );
    });

    test('previewFadeAt covers dual-layer transitions including wipe', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transitionId: 'wipeleft',
          transitionDuration: const Duration(milliseconds: 500),
        ),
        ClipSegment(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];

      // Centered window [2750, 3250); mid at cut.
      final mid = previewFadeAt(segments, const Duration(seconds: 3));
      expect(mid, isNotNull);
      expect(mid!.afterIndex, 0);
      expect(mid.t, closeTo(0.5, 0.02));
    });

    test('previewFadeAt returns null on last segment / single clip', () {
      expect(
        previewFadeAt(
          [
            ClipSegment(
              start: Duration.zero,
              end: const Duration(seconds: 3),
              transitionId: 'fade',
            ),
          ],
          const Duration(milliseconds: 2800),
        ),
        isNull,
      );
    });

    test('project stores applied transition id/version/params', () {
      final segment = ClipSegment(
        start: Duration.zero,
        end: const Duration(seconds: 2),
        transition: const AppliedTransition(
          id: 'zoomin',
          version: 1,
          duration: Duration(milliseconds: 400),
          parameters: {'intensity': 0.8},
        ),
      );
      final json = segment.toJson();
      expect(json['transition'], isA<Map>());
      expect(json['transitionId'], 'zoomin');
      expect(json['transitionMs'], 400);

      final restored = ClipSegment.fromJson(json);
      expect(restored.transition?.id, 'zoomin');
      expect(restored.transition?.version, 1);
      expect(restored.transition?.parameters['intensity'], 0.8);
    });

    test('legacy transitionId migrates on load', () {
      final restored = ClipSegment.fromJson({
        'id': 'seg1',
        'startMs': 0,
        'endMs': 2000,
        'transitionId': 'slide_left',
        'transitionMs': 350,
      });
      expect(restored.transition?.id, 'slideleft');
      expect(restored.transition?.version, 1);
      expect(restored.transitionDuration, const Duration(milliseconds: 350));
    });
  });

  group('transition catalog v3 + engine', () {
    test('bundled catalog is single iMovie-style basic category', () async {
      final raw =
          await rootBundle.loadString('assets/transitions/catalog.json');
      final catalog = TransitionCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );

      expect(catalog.version, 26);
      expect(catalog.displayCategories.length, 1);
      expect(catalog.displayCategories.single.id, 'basic');
      expect(catalog.byId('fade'), isNull);
      expect(catalog.byId('none'), isNull);
      expect(catalog.byId('dissolve')?.renderer, TransitionRendererKind.xfade);
      expect(catalog.byId('dissolve')?.effectName, 'dissolve');
      expect(catalog.byId('dissolve')?.localizedTitle('ko'), isNotEmpty);
      expect(catalog.byId('slideleft')?.effectName, 'slideleft');
      expect(catalog.byId('crossblur')?.renderer, TransitionRendererKind.primitive);
      expect(catalog.byId('circleclose')?.title, 'Circle Close');
      expect(catalog.byId('doorway')?.renderer, TransitionRendererKind.custom);
      expect(catalog.byId('doorway')?.effect?['kind'], 'doorway');
      expect(catalog.byId('puzzleleft')?.effect?['kind'], 'puzzle');
      expect(catalog.byId('puzzleright')?.effect?['reverse'], isTrue);
      expect(
        catalog.items.map((e) => e.id).toSet(),
        containsAll([
          'dissolve',
          'slideleft',
          'swap',
          'doorway',
          'spinin',
          'mosaic',
          'ripple',
          'crossblur',
          'wipeleft',
          'crosszoom',
        ]),
      );
      expect(catalog.byId('pushleft'), isNull);
      expect(catalog.byId('pagecurl'), isNull);
    });

    test('engine plans export + preview from the same definition', () async {
      await TransitionCatalogService.instance.ensureInitialized();
      final engine = TransitionEngine(catalog: TransitionCatalogService.instance);

      final dissolve = engine.plan(
        const AppliedTransition(
          id: 'dissolve',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      );
      expect(dissolve.effectName, 'dissolve');
      expect(dissolve.previewKind, TransitionPreviewKind.dualLayer);
      expect(dissolve.supportedInExport, isTrue);

      final slide = engine.plan(
        const AppliedTransition(
          id: 'slideleft',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      );
      expect(slide.effectName, 'slideleft');
      expect(slide.previewKind, TransitionPreviewKind.dualLayer);

      final fadeblack = engine.plan(
        const AppliedTransition(
          id: 'fadeblack',
          version: 1,
          duration: Duration(milliseconds: 700),
        ),
      );
      expect(fadeblack.effectName, 'fadeblack');
      expect(fadeblack.renderer, TransitionRendererKind.primitive);

      final doorway = engine.plan(
        const AppliedTransition(
          id: 'doorway',
          version: 1,
          duration: Duration(milliseconds: 700),
        ),
      );
      expect(doorway.renderer, TransitionRendererKind.custom);
      expect(doorway.previewKind, TransitionPreviewKind.dualLayer);
      expect(doorway.effectName, 'horzopen');
      expect(doorway.fallbackReason, 'custom_export_bridge');
      expect(doorway.definition?.hasRoleCompositor, isTrue);

      final spin = ExportService.transitionMotionFor(
        const AppliedTransition(
          id: 'spinin',
          version: 1,
          duration: Duration(milliseconds: 700),
        ),
      );
      expect(spin.map((e) => e['property']), containsAll(['rotation', 'scale']));
      expect(
        spin.firstWhere(
          (e) => e['property'] == 'scale' && e['target'] == 'B',
        )['from'],
        0,
      );
      expect(
        spin.firstWhere((e) => e['property'] == 'rotation')['target'],
        'B',
      );
    });

    test('every catalog transition is sent for album save', () async {
      await TransitionCatalogService.instance.ensureInitialized();
      final catalog = TransitionCatalogService.instance.catalog;
      expect(catalog.items, isNotEmpty);
      const namedOnly = {
        'circleopen',
        'circleclose',
      };
      for (final item in catalog.items) {
        final applied = AppliedTransition(
          id: item.id,
          version: item.itemVersion,
          duration: Duration(milliseconds: item.defaultDurationMs),
          parameters: item.defaultParameters(),
        );
        final project = VideoProject(
          id: 'export-${item.id}',
          sourcePath: '/tmp/in.mp4',
          duration: const Duration(seconds: 8),
          segments: [
            ClipSegment(
              start: Duration.zero,
              end: const Duration(seconds: 4),
              transition: applied,
            ),
            ClipSegment(
              start: const Duration(seconds: 4),
              end: const Duration(seconds: 8),
            ),
          ],
        );
        final request = ExportService().buildNativeExportRequestForTest(
          project: project,
          rasters: const [],
          quality: ExportQualityProfile.high,
          frame: const ExportFrameSize(
            width: 720,
            height: 1280,
            scaleWidth: 720,
            scaleHeight: 1280,
          ),
          outputPath: '/tmp/out.mp4',
        );
        final segments = request['segments'] as List;
        final first = segments.first as Map;
        expect(first['transitionDurationMs'], greaterThan(0), reason: item.id);
        expect(first['transitionEffect'], isNotNull, reason: item.id);
        final layers = first['transitionLayers'] as List?;
        final kind = first['transitionKind'] as String?;
        final effect = first['transitionEffect'] as String;
        final covered = (layers != null && layers.isNotEmpty) ||
            kind == 'doorway' ||
            kind == 'puzzle' ||
            namedOnly.contains(effect);
        expect(covered, isTrue, reason: '${item.id} effect=$effect kind=$kind layers=${layers?.length}');
        if (item.id == 'spinin' || item.id == 'spinout') {
          expect(
            layers!.map((e) => (e as Map)['property']),
            containsAll(['rotation', 'scale']),
            reason: '${item.id} must bake rotation, not a circle fade',
          );
        }
        if (item.id == 'doorway') {
          expect(kind, 'doorway');
          final params = first['transitionParams'] as Map;
          expect(params['incomingScaleFrom'], 0.84);
        }
        if (item.id == 'puzzleright') {
          expect(kind, 'puzzle');
          expect(first['transitionReverse'], isTrue);
        }
        if (item.id == 'puzzleleft') {
          expect(first['transitionReverse'], isFalse);
        }
        if (item.id == 'wiperight') {
          expect(kind, isNull);
          expect(
            layers!.map((e) => (e as Map)['property']),
            contains('wipe'),
          );
          final wipe = layers.cast<Map>().firstWhere((e) => e['property'] == 'wipe');
          expect(wipe['target'], 'A');
          expect(wipe['mode'], 'left');
        }
        if (item.id == 'wipeleft') {
          final wipe = layers!.cast<Map>().firstWhere((e) => e['property'] == 'wipe');
          expect(wipe['mode'], 'right');
        }
      }
    });

    test('remote xfade id wins merge', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('transitions/catalog.json')) {
          return http.Response(
            jsonEncode({
              'version': 3,
              'baseUrl': 'https://cdn.example/',
              'categories': [
                {
                  'id': 'effect',
                  'title': 'Effect',
                  'items': [
                    {
                      'id': 'glitch',
                      'version': 1,
                      'title': 'Glitch',
                      'category': 'effect',
                      'renderer': 'shader',
                      'shader': 'glitch_v1',
                      'effectName': 'fade',
                      'defaultDurationMs': 400,
                      'minDurationMs': 100,
                      'maxDurationMs': 2000,
                      'accent': '#22D3EE',
                    },
                  ],
                },
              ],
              'items': [
                {
                  'id': 'glitch',
                  'version': 1,
                  'title': 'Glitch',
                  'category': 'effect',
                  'renderer': 'shader',
                  'shader': 'glitch_v1',
                  'effectName': 'fade',
                  'defaultDurationMs': 400,
                  'accent': '#22D3EE',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      final service = TransitionCatalogService(httpClient: client);
      await service.refresh(awaitRemote: true);

      expect(service.itemById('glitch')?.renderer, TransitionRendererKind.shader);
      expect(service.itemById('glitch')?.shader, 'glitch_v1');
      expect(service.itemById('dissolve')?.effectName, 'dissolve');

      final plan = TransitionEngine(catalog: service).plan(
        const AppliedTransition(
          id: 'glitch',
          version: 1,
          duration: Duration(milliseconds: 400),
        ),
      );
      expect(plan.effectName, 'fade');
      expect(plan.fallbackReason, isNotNull);
    });

    test('legacy flat catalog without categories still works', () {
      final catalog = TransitionCatalog.fromJson({
        'version': 1,
        'items': [
          {
            'id': 'fade',
            'title': 'Fade',
            'ffmpegName': 'fade',
            'defaultDurationMs': 500,
            'accent': '#60A5FA',
          },
        ],
      });
      expect(catalog.displayCategories.single.id, 'all');
      expect(catalog.byId('fade')?.renderer, TransitionRendererKind.xfade);
    });
  });
}
