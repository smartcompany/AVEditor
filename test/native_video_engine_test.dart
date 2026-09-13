import 'package:aveditor/models/applied_transition.dart';
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
  });
}
