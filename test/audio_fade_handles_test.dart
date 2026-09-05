import 'package:aveditor/widgets/timeline_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('short middle cut keeps distinct fade-in and fade-out knobs', () {
    // ~30px bar after a 3-way split at default zoom — old inset (18*2+8)
    // rejected hit-testing entirely and collapsed knobs.
    const left = 100.0;
    const right = 130.0;
    final xs = audioFadeHandleXs(
      left: left,
      right: right,
      fadeIn: Duration.zero,
      fadeOut: Duration.zero,
      duration: const Duration(seconds: 2),
    );

    expect(xs.inX, lessThan(xs.outX));
    expect(xs.inX, greaterThanOrEqualTo(left));
    expect(xs.outX, lessThanOrEqualTo(right));
    expect(audioFadeHandleInset(right - left), lessThan(18));
  });

  test('wide clip keeps ideal edge inset', () {
    expect(audioFadeHandleInset(120), 18);
    final xs = audioFadeHandleXs(
      left: 0,
      right: 200,
      fadeIn: Duration.zero,
      fadeOut: Duration.zero,
      duration: const Duration(seconds: 5),
    );
    expect(xs.inX, 18);
    expect(xs.outX, 182);
  });
}
