import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canStreamCopy', () {
    test('background music disables stream copy', () {
      expect(
        ExportService.canStreamCopy(
          project: _emptyProject(),
          rasters: const [],
          quality: ExportQualityProfile.recommended,
          musicPath: '/tmp/music.mp3',
        ),
        isFalse,
      );
    });
  });
}

VideoProject _emptyProject() {
  return VideoProject(
    id: 'p',
    sourcePath: '/tmp/p/source.mp4',
    duration: const Duration(seconds: 10),
  );
}
