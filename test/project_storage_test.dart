import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/project_storage_service.dart';
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
      expect(restored.duration, project.duration);
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

    test('createFromImport copies the source and writes project.json', () async {
      final picked = File('${tempRoot.path}/picked.mp4');
      await picked.writeAsBytes(List<int>.filled(2048, 7));

      final projectId = await service.createFromImport(picked.path);
      final loaded = await service.load(projectId);

      expect(loaded, isNotNull);
      expect(await File(loaded!.sourcePath).exists(), isTrue);
      expect(await File(loaded.sourcePath).length(), greaterThan(1024));

      final json = jsonDecode(
        await File('${tempRoot.path}/aveditor/projects/$projectId/project.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(json['id'], projectId);
      expect(json['durationMs'], 0);
    });

    test('listSummaries returns all projects newest first', () async {
      final first = File('${tempRoot.path}/a.mp4');
      final second = File('${tempRoot.path}/b.mp4');
      await first.writeAsBytes(List<int>.filled(512, 1));
      await second.writeAsBytes(List<int>.filled(512, 2));

      final idA = await service.createFromImport(first.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final idB = await service.createFromImport(second.path);

      final list = await service.listSummaries();
      expect(list.map((s) => s.id), [idB, idA]);
      expect(list.every((s) => s.sourceExists), isTrue);
    });
  });
}
