import 'dart:convert';

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
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

    test('exportTimelineDuration subtracts xfade overlaps', () {
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

      expect(totalKeptDuration(segments), const Duration(seconds: 6));
      expect(
        exportTimelineDuration(segments),
        const Duration(milliseconds: 5500),
      );
    });

    test('buildSegmentConcatGraph uses xfade when transition set', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 2),
          transitionId: 'dissolve',
          transitionDuration: const Duration(milliseconds: 400),
        ),
        ClipSegment(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 4),
        ),
      ];

      final graph = ExportService.buildSegmentConcatGraph(segments)!;
      expect(graph, contains('xfade=transition=dissolve'));
      expect(graph, contains('acrossfade=d=0.400'));
      expect(graph, contains('[vcat]'));
      expect(graph, contains('[acat]'));
    });

    test('transitionSequenceSpan centers on the cut', () {
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
      expect(span.start, const Duration(milliseconds: 2750));
      expect(span.end, const Duration(milliseconds: 3250));
    });

    test('buildSegmentConcatGraph keeps concat without transitions', () {
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 2),
        ),
        ClipSegment(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 4),
        ),
      ];

      final graph = ExportService.buildSegmentConcatGraph(segments)!;
      expect(graph, contains('concat=n=2:v=1:a=1[vcat][acat]'));
      expect(graph, isNot(contains('xfade')));
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
        previewFadeAt(segments, const Duration(milliseconds: 2499)),
        isNull,
      );

      final mid = previewFadeAt(segments, const Duration(milliseconds: 2750))!;
      expect(mid.afterIndex, 0);
      expect(mid.t, closeTo(0.5, 0.02));
      expect(mid.td, const Duration(milliseconds: 500));
      expect(mid.auxSourceTime, const Duration(milliseconds: 3250));

      expect(previewFadeAt(segments, const Duration(seconds: 3)), isNull);
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

      final mid = previewFadeAt(segments, const Duration(milliseconds: 2750));
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
    test('bundled catalog parses renderer, layers, categories', () async {
      final raw =
          await rootBundle.loadString('assets/transitions/catalog.json');
      final catalog = TransitionCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );

      expect(catalog.version, 3);
      expect(catalog.displayCategories, isNotEmpty);
      expect(catalog.byId('fade')?.renderer, TransitionRendererKind.xfade);
      expect(catalog.byId('none')?.renderer, TransitionRendererKind.cut);
      expect(catalog.byId('flash')?.renderer, TransitionRendererKind.primitive);
      expect(catalog.byId('zoomin')?.controls, isNotEmpty);
      expect(catalog.byId('fade')?.ffmpegName, 'fade');
      expect(catalog.byId('pushleft')?.ffmpegName, 'coverleft');
    });

    test('engine plans export + preview from the same definition', () async {
      await TransitionCatalogService.instance.ensureInitialized();
      final engine = TransitionEngine(catalog: TransitionCatalogService.instance);

      final fade = engine.plan(
        const AppliedTransition(
          id: 'fade',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      );
      expect(fade.xfadeName, 'fade');
      expect(fade.previewKind, TransitionPreviewKind.dualLayer);
      expect(fade.supportedInExport, isTrue);

      final push = engine.plan(
        const AppliedTransition(
          id: 'pushleft',
          version: 1,
          duration: Duration(milliseconds: 500),
        ),
      );
      expect(push.xfadeName, 'coverleft');
      expect(push.previewKind, TransitionPreviewKind.dualLayer);

      final flash = engine.plan(
        const AppliedTransition(
          id: 'flash',
          version: 1,
          duration: Duration(milliseconds: 250),
        ),
      );
      expect(flash.xfadeName, 'fadewhite');
      expect(flash.renderer, TransitionRendererKind.primitive);
    });

    test('export graph uses engine ffmpeg bridge for push', () async {
      await TransitionCatalogService.instance.ensureInitialized();
      final segments = [
        ClipSegment(
          start: Duration.zero,
          end: const Duration(seconds: 2),
          transition: const AppliedTransition(
            id: 'pushleft',
            version: 1,
            duration: Duration(milliseconds: 400),
          ),
        ),
        ClipSegment(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 4),
        ),
      ];
      final graph = ExportService.buildSegmentConcatGraph(segments)!;
      expect(graph, contains('xfade=transition=coverleft'));
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
                      'ffmpegName': 'fade',
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
                  'ffmpegName': 'fade',
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
      await service.refresh();

      expect(service.itemById('glitch')?.renderer, TransitionRendererKind.shader);
      expect(service.itemById('glitch')?.shader, 'glitch_v1');
      expect(service.itemById('fade')?.ffmpegName, 'fade');

      final plan = TransitionEngine(catalog: service).plan(
        const AppliedTransition(
          id: 'glitch',
          version: 1,
          duration: Duration(milliseconds: 400),
        ),
      );
      expect(plan.xfadeName, 'fade');
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
