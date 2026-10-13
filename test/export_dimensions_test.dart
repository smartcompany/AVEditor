import 'package:aveditor/models/canvas_ratio.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeExportFrameSize', () {
    test('caps 4K portrait to 1080x1920 without upscaling logic change', () {
      final frame = computeExportFrameSize(
        sourceWidth: 2160,
        sourceHeight: 3840,
        maxWidth: 1080,
        maxHeight: 1920,
        allowUpscale: false,
      );

      expect(frame.width, 1080);
      expect(frame.height, 1920);
      expect(frame.scaleWidth, greaterThanOrEqualTo(1080));
      expect(frame.scaleHeight, greaterThanOrEqualTo(1920));
    });

    test('does not upscale sub-1080p sources', () {
      final frame = computeExportFrameSize(
        sourceWidth: 720,
        sourceHeight: 1280,
        maxWidth: 1080,
        maxHeight: 1920,
        allowUpscale: false,
      );

      expect(frame.width, 720);
      expect(frame.height, 1280);
      expect(frame.scaleWidth, 720);
      expect(frame.scaleHeight, 1280);
    });

    test('dimensions are always even', () {
      final frame = computeExportFrameSize(
        sourceWidth: 721,
        sourceHeight: 1281,
        maxWidth: 1080,
        maxHeight: 1920,
        allowUpscale: false,
      );

      expect(frame.width.isEven, isTrue);
      expect(frame.height.isEven, isTrue);
      expect(frame.scaleWidth.isEven, isTrue);
      expect(frame.scaleHeight.isEven, isTrue);
    });
  });

  group('computeCanvasFrameSize', () {
    test('original portrait keeps the source ratio under the 1080 cap', () {
      final frame = computeCanvasFrameSize(
        sourceWidth: 720,
        sourceHeight: 1280,
        canvasAspect: 720 / 1280,
        allowUpscale: false,
      );

      expect(frame.width, 720);
      expect(frame.height, 1280);
    });

    test('original landscape is 16:9 at 1080 on the short side', () {
      final frame = computeCanvasFrameSize(
        sourceWidth: 3840,
        sourceHeight: 2160,
        canvasAspect: 16 / 9,
        allowUpscale: false,
      );

      expect(frame.width, 1920);
      expect(frame.height, 1080);
    });

    test('9:16 canvas letterboxes a landscape source into 1080x1920', () {
      final frame = computeCanvasFrameSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        canvasAspect: 9 / 16,
        allowUpscale: false,
      );

      expect(frame.width, 1080);
      expect(frame.height, 1920);
    });
  });

  group('canStreamCopy', () {
    VideoProject trimOnlyProject({double rotation = 0}) => VideoProject(
          id: 'p',
          sourcePath: '/tmp/in.mp4',
          duration: const Duration(seconds: 10),
          rotation: rotation,
        );

    test('trim-only with recommended profile uses stream copy', () {
      expect(
        ExportService.canStreamCopy(
          project: trimOnlyProject(),
          rasters: const [],
          quality: ExportQualityProfile.recommended,
        ),
        isTrue,
      );
    });

    test('high quality always re-encodes', () {
      expect(
        ExportService.canStreamCopy(
          project: trimOnlyProject(),
          rasters: const [],
          quality: ExportQualityProfile.high,
        ),
        isFalse,
      );
    });

    test('rotation blocks stream copy', () {
      expect(
        ExportService.canStreamCopy(
          project: trimOnlyProject(rotation: 1.57),
          rasters: const [],
          quality: ExportQualityProfile.recommended,
        ),
        isFalse,
      );
    });

    test('a chosen canvas ratio blocks stream copy', () {
      final project = trimOnlyProject()..canvas = CanvasRatio.vertical;
      expect(
        ExportService.canStreamCopy(
          project: project,
          rasters: const [],
          quality: ExportQualityProfile.recommended,
        ),
        isFalse,
      );
    });
  });
}
