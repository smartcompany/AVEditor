import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/services/playback_fallback_transcoder.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoProject serialization', () {
    test('round-trips overlays, trim, and rotation', () {
      final overlay = TextOverlay(
        id: 'overlay-1',
        text: 'hello',
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 4),
        offset: const Offset(0.2, -0.1),
        rotation: 0.5,
      );
      final project = VideoProject(
        id: 'project-1',
        sourcePath: '/tmp/projects/project-1/source.mp4',
        duration: const Duration(seconds: 10),
        trim: const ClipTrim(
          start: Duration(seconds: 1),
          end: Duration(seconds: 8),
        ),
        overlays: [overlay],
        preset: ExportPreset.youtubeShorts,
        rotation: 1.2,
        updatedAt: DateTime.utc(2026, 3, 1, 12),
      );

      final restored = VideoProject.fromJson(
        project.toJson(),
        sourcePath: project.sourcePath,
      );

      expect(restored.id, project.id);
      // Duration is the packed timeline (kept segment length), not master EOF.
      expect(restored.duration, const Duration(seconds: 7));
      expect(restored.trim.start, project.trim.start);
      expect(restored.trim.end, project.trim.end);
      expect(restored.segments.length, 1);
      expect(restored.rotation, project.rotation);
      expect(restored.preset, project.preset);
      expect(restored.overlays.length, 1);
      expect(restored.overlays.first.text, 'hello');
      expect(restored.overlays.first.rotation, 0.5);
      expect(restored.overlays.first.offset, const Offset(0.2, -0.1));
    });

    test('round-trips the project name and leaves it null when unset', () {
      VideoProject build({String? name}) => VideoProject(
        id: 'project-name',
        sourcePath: '/tmp/projects/project-name/source.mp4',
        duration: const Duration(seconds: 5),
        name: name,
        updatedAt: DateTime.utc(2026, 3, 1, 12),
      );

      final named = VideoProject.fromJson(
        build(name: '여행 브이로그').toJson(),
        sourcePath: '/tmp/x.mp4',
      );
      expect(named.name, '여행 브이로그');
      expect(named.copyWith(rotation: 1).name, '여행 브이로그');
      expect(named.withSourcePath('/tmp/y.mp4').name, '여행 브이로그');

      final unnamed = build().toJson();
      expect(unnamed.containsKey('name'), isFalse);
      expect(
        VideoProject.fromJson(unnamed, sourcePath: '/tmp/x.mp4').name,
        isNull,
      );
    });

    test('round-trips multi-segment cuts', () {
      final project = VideoProject(
        id: 'project-cuts',
        sourcePath: '/tmp/projects/project-cuts/source.mp4',
        duration: const Duration(seconds: 20),
        segments: [
          ClipSegment(
            id: 'a',
            start: Duration.zero,
            end: const Duration(seconds: 8),
          ),
          ClipSegment(
            id: 'b',
            start: const Duration(seconds: 8),
            end: const Duration(seconds: 20),
          ),
        ],
        updatedAt: DateTime.utc(2026, 3, 1, 12),
      );

      final restored = VideoProject.fromJson(
        project.toJson(),
        sourcePath: project.sourcePath,
      );

      expect(restored.segments.length, 2);
      expect(restored.segments[0].end, const Duration(seconds: 8));
      expect(restored.segments[1].start, const Duration(seconds: 8));
    });

    test('empty segments fall back to full duration trim', () {
      final json = VideoProject(
        id: 'project-empty-segments',
        sourcePath: '/tmp/projects/project-empty-segments/source.mp4',
        duration: const Duration(seconds: 10),
        updatedAt: DateTime.utc(2026, 3, 1, 12),
      ).toJson();
      json['segments'] = <dynamic>[];

      final restored = VideoProject.fromJson(
        json,
        sourcePath: '/tmp/projects/project-empty-segments/source.mp4',
      );

      expect(restored.segments.length, 1);
      expect(restored.trim.start, Duration.zero);
      expect(restored.trim.end, const Duration(seconds: 10));
      expect(restored.trimmedDuration, const Duration(seconds: 10));
    });

    test('trim getter is safe when segments list is cleared', () {
      final project = VideoProject(
        id: 'project-cleared',
        sourcePath: '/tmp/projects/project-cleared/source.mp4',
        duration: const Duration(seconds: 10),
      );
      project.segments.clear();

      expect(project.trim.start, Duration.zero);
      expect(project.trim.end, const Duration(seconds: 10));
      expect(project.trimmedDuration, Duration.zero);
    });

    test('v1 JSON migrates to one MediaAsset and mediaIds', () {
      final json = <String, dynamic>{
        'version': 1,
        'id': 'legacy',
        'durationMs': 8000,
        'sourceFileName': 'source.mp4',
        'preset': ExportPreset.youtubeShorts.name,
        'segments': [
          {
            'id': 'a',
            'startMs': 0,
            'endMs': 3000,
            'volume': 1.0,
            'fadeInMs': 0,
            'fadeOutMs': 0,
            'transitionMs': 500,
          },
          {
            'id': 'b',
            'startMs': 3000,
            'endMs': 8000,
            'volume': 1.0,
            'fadeInMs': 0,
            'fadeOutMs': 0,
            'transitionMs': 500,
          },
        ],
        'updatedAt': '2026-03-01T12:00:00.000Z',
      };

      final restored = VideoProject.fromJson(
        json,
        sourcePath: '/tmp/projects/legacy/source.mp4',
      );

      expect(restored.mediaAssets, hasLength(1));
      expect(restored.mediaAssets.first.fileName, 'source.mp4');
      expect(restored.mediaAssets.first.kind, MediaAssetKind.video);
      expect(restored.mediaAssets.first.duration, const Duration(seconds: 8));
      expect(restored.segments.every((s) => s.mediaId != null), isTrue);
      expect(
        restored.segments.map((s) => s.mediaId).toSet(),
        {restored.mediaAssets.first.id},
      );
      expect(restored.toJson()['version'], kProjectFileVersion);
    });

    test('round-trips mediaAssets and segment mediaIds', () {
      final assetA = MediaAsset(
        id: 'ma',
        fileName: 'media/ma.mp4',
        kind: MediaAssetKind.video,
        duration: const Duration(seconds: 4),
      );
      final assetB = MediaAsset(
        id: 'mb',
        fileName: 'media/mb.jpg',
        kind: MediaAssetKind.image,
      );
      final project = VideoProject(
        id: 'multi',
        sourcePath: '/tmp/projects/multi/media/ma.mp4',
        duration: const Duration(seconds: 7),
        mediaAssets: [assetA, assetB],
        segments: [
          ClipSegment(
            id: 'a',
            mediaId: assetA.id,
            start: Duration.zero,
            end: const Duration(seconds: 4),
          ),
          ClipSegment(
            id: 'b',
            mediaId: assetB.id,
            start: Duration.zero,
            end: kDefaultImageHoldDuration,
          ),
        ],
        updatedAt: DateTime.utc(2026, 3, 1, 12),
      );

      final restored = VideoProject.fromJson(
        project.toJson(),
        sourcePath: project.sourcePath,
      );
      expect(restored.mediaAssets, hasLength(2));
      expect(restored.segments[0].mediaId, assetA.id);
      expect(restored.segments[1].mediaId, assetB.id);
      expect(restored.pathForSegment(restored.segments[1]), endsWith('mb.jpg'));
    });
  });

  group('ProjectStorageService', () {
    late Directory tempRoot;
    late ProjectStorageService service;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('project_storage_test_');
      service = ProjectStorageService(
        rootOverride: Directory('${tempRoot.path}/aveditor'),
      );
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('createFromImport copies into media/ and writes project.json', () async {
      final picked = File('${tempRoot.path}/picked.mp4');
      await picked.writeAsBytes(List<int>.filled(2048, 7));

      final projectId = await service.createFromImport(
        picked.path,
        concat: _FakeMediaConcat(),
      );
      final loaded = await service.load(projectId);

      expect(loaded, isNotNull);
      expect(loaded!.mediaAssets, hasLength(1));
      expect(loaded.mediaAssets.first.fileName, startsWith('media/'));
      expect(await File(loaded.primaryVideoPath).exists(), isTrue);
      expect(await File(loaded.primaryVideoPath).length(), greaterThan(1024));
      expect(loaded.segments.single.mediaId, loaded.mediaAssets.first.id);
      expect(loaded.duration, const Duration(seconds: 2));

      final json =
          jsonDecode(
                await File(
                  '${tempRoot.path}/aveditor/projects/$projectId/project.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(json['id'], projectId);
      expect(json['version'], kProjectFileVersion);
      expect(json['mediaAssets'], hasLength(1));
    });

    test(
      'createFromImport replaces an unplayable media file in place',
      () async {
        final picked = File('${tempRoot.path}/picked.mov');
        await picked.writeAsString('hevc-original');
        final converting = ProjectStorageService(
          rootOverride: Directory('${tempRoot.path}/aveditor'),
          transcoder: PlaybackFallbackTranscoder(
            shouldTranscode: (_) async => true,
            run: (arguments) async {
              await File(arguments.last).writeAsString('h264-sdr');
              return true;
            },
          ),
        );

        final projectId = await converting.createFromImport(
          picked.path,
          concat: _FakeMediaConcat(),
        );
        final loaded = await converting.load(projectId);

        expect(loaded!.sourcePath, endsWith('/source.mp4'));
        expect(await File(loaded.sourcePath).readAsString(), 'h264-sdr');
        expect(loaded.mediaAssets.single.fileName, contains('source.mp4'));
        expect(await picked.readAsString(), 'hevc-original');
      },
    );

    test('listSummaries returns all projects newest first', () async {
      final first = File('${tempRoot.path}/a.mp4');
      final second = File('${tempRoot.path}/b.mp4');
      await first.writeAsBytes(List<int>.filled(512, 1));
      await second.writeAsBytes(List<int>.filled(512, 2));

      final idA = await service.createFromImport(
        first.path,
        concat: _FakeMediaConcat(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final idB = await service.createFromImport(
        second.path,
        concat: _FakeMediaConcat(),
      );

      final list = await service.listSummaries();
      expect(list.map((s) => s.id), [idB, idA]);
      expect(list.every((s) => s.sourceExists), isTrue);
    });

    test('summary cover time follows the first clip start', () async {
      final source = File('${tempRoot.path}/c.mp4');
      await source.writeAsBytes(List<int>.filled(512, 3));
      final id = await service.createFromImport(
        source.path,
        concat: _FakeMediaConcat(),
      );

      final loaded = (await service.load(id))!;
      await service.save(
        VideoProject(
          id: id,
          sourcePath: loaded.sourcePath,
          duration: const Duration(seconds: 10),
          mediaAssets: loaded.mediaAssets,
          segments: [
            ClipSegment(
              id: 'trimmed',
              mediaId: loaded.mediaAssets.first.id,
              start: const Duration(milliseconds: 1500),
              end: const Duration(seconds: 4),
            ),
          ],
        ),
      );

      final summary = (await service.loadSummary(id))!;
      expect(summary.coverTimeMs, 1500);
    });

    test('createFromImports copies each pick under media/ without concat', () async {
      final video = File('${tempRoot.path}/clip.mp4');
      final image = File('${tempRoot.path}/still.jpg');
      await video.writeAsBytes(List<int>.filled(512, 4));
      await image.writeAsBytes(List<int>.filled(128, 5));

      final id = await service.createFromImports(
        [video.path, image.path, video.path],
        concat: _FakeMediaConcat(),
      );
      final loaded = (await service.load(id))!;

      expect(loaded.mediaAssets, hasLength(3));
      expect(loaded.mediaAssets[0].kind, MediaAssetKind.video);
      expect(loaded.mediaAssets[1].kind, MediaAssetKind.image);
      expect(loaded.mediaAssets[2].kind, MediaAssetKind.video);
      expect(
        loaded.duration,
        const Duration(seconds: 2) +
            kDefaultImageHoldDuration +
            const Duration(seconds: 4),
      );
      expect(loaded.segments, hasLength(3));
      expect(loaded.segments[0].start, Duration.zero);
      expect(loaded.segments[0].end, const Duration(seconds: 2));
      expect(loaded.segments[0].mediaId, loaded.mediaAssets[0].id);
      expect(loaded.segments[1].start, Duration.zero);
      expect(loaded.segments[1].end, kDefaultImageHoldDuration);
      expect(loaded.segments[1].mediaId, loaded.mediaAssets[1].id);
      expect(loaded.segments[2].start, Duration.zero);
      expect(loaded.segments[2].end, const Duration(seconds: 4));
      expect(loaded.segments[2].mediaId, loaded.mediaAssets[2].id);

      for (final asset in loaded.mediaAssets) {
        expect(await File(loaded.absoluteMediaPath(asset)).exists(), isTrue);
      }

      // Image right edge can grow hold length up to the soft max.
      final extended = trimSegmentEnd(
        loaded.segments,
        loaded.segments[1],
        nextEnd: const Duration(seconds: 12),
        asset: loaded.mediaAssets[1],
      )!;
      expect(extended.end, const Duration(seconds: 12));
    });
  });

  test('MediaConcatService classifies image paths', () {
    expect(MediaConcatService.isImagePath('/a/b/c.JPG'), isTrue);
    expect(MediaConcatService.isImagePath('/a/b/c.png'), isTrue);
    expect(MediaConcatService.isImagePath('/a/b/c.mp4'), isFalse);
    expect(kDefaultImageHoldDuration, const Duration(seconds: 3));
    expect(kMaxImageHoldDuration, const Duration(minutes: 5));
    expect(kMaxImageHoldDuration > kDefaultImageHoldDuration, isTrue);
  });
}

class _FakeMediaConcat extends MediaConcatService {
  int _videoProbeCount = 0;

  @override
  Future<Duration?> probeDuration(String path) async {
    if (MediaConcatService.isImagePath(path)) return null;
    final lengths = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    final d = lengths[_videoProbeCount % lengths.length];
    _videoProbeCount++;
    return d;
  }

  @override
  Future<({String outputPath, List<Duration> pieceDurations})> buildSource({
    required List<String> inputPaths,
    required String workDir,
    void Function(double progress)? onProgress,
  }) async {
    fail('buildSource must not be called for multi-source import');
  }
}
