import 'dart:io';

import 'package:aveditor/services/export_save_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExportSaveService', () {
    late ExportSaveService service;
    late Directory tempDir;

    setUp(() async {
      service = ExportSaveService();
      tempDir = await Directory.systemTemp.createTemp('export_save_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('rejects a missing export file', () async {
      await expectLater(
        service.saveExportedVideo('${tempDir.path}/missing.mp4'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('export_file_missing'),
        )),
      );
    });

    test('rejects an empty export file', () async {
      final file = File('${tempDir.path}/empty.mp4');
      await file.writeAsBytes([1, 2, 3]);

      await expectLater(
        service.saveExportedVideo(file.path),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('export_file_empty'),
        )),
      );
    });
  });
}
