import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NativeVideoEngine', () {
    test('isSpatialPreview distinguishes slide from fade', () {
      expect(
        NativeVideoEngine.isSpatialPreview(
          const AppliedTransition(
            id: 'slideleft',
            version: 1,
            duration: Duration(milliseconds: 500),
          ),
        ),
        isTrue,
      );
      expect(
        NativeVideoEngine.isSpatialPreview(
          const AppliedTransition(
            id: 'fade',
            version: 1,
            duration: Duration(milliseconds: 500),
          ),
        ),
        isFalse,
      );
    });

    test('supportedEffects covers slide and push conveyor', () {
      expect(NativeVideoEngine.supportedEffects.contains('slideleft'), isTrue);
      expect(NativeVideoEngine.supportedEffects.contains('pushup'), isTrue);
      expect(NativeVideoEngine.supportedEffects.contains('fade'), isFalse);
    });

    test('buildTimelineSegments includes transition fields', () {
      final segments = [
        ClipSegment(
          id: 'a',
          start: Duration.zero,
          end: const Duration(seconds: 3),
          transition: const AppliedTransition(
            id: 'slideleft',
            version: 1,
            duration: Duration(milliseconds: 500),
          ),
        ),
        ClipSegment(
          id: 'b',
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 6),
        ),
      ];
      final maps = NativeVideoEngine.buildTimelineSegments(segments);
      expect(maps, hasLength(2));
      expect(maps.first['transitionDurationMs'], greaterThan(0));
      expect(maps.last.containsKey('transitionEffect'), isFalse);
    });

    test('supportsTimeline follows platform', () {
      expect(
        NativeVideoEngine.supportsTimeline,
        NativeVideoEngine.instance.isPlatformSupported,
      );
    });
  });
}
