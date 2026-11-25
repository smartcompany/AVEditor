import 'package:aveditor/models/text_composition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('textsFor maps lines onto slots and folds extras into last', () {
    final composition = TextComposition(
      slots: const [
        TextCompSlot(id: 'a', defaultText: 'A'),
        TextCompSlot(id: 'b', defaultText: 'B'),
        TextCompSlot(id: 'c', defaultText: 'C'),
      ],
    );

    expect(composition.textsFor('one\ntwo\nthree'), ['one', 'two', 'three']);
    expect(composition.textsFor('only'), ['only', '', '']);
    expect(composition.textsFor('a\nb\nc\nd\ne'), ['a', 'b', 'c\nd\ne']);
  });

  test('repeatSlots cycles styles per newline', () {
    final composition = TextComposition(
      repeatSlots: true,
      slots: const [
        TextCompSlot(id: 'm1', defaultText: 'hey'),
        TextCompSlot(id: 'm2', defaultText: 'reply'),
        TextCompSlot(id: 'm3', defaultText: 'again'),
      ],
    );

    expect(composition.textsFor('a\nb\nc\nd'), ['a', 'b', 'c', 'd']);
    expect(composition.paintedSlotCount('a\nb\nc\nd'), 4);
    final entries = composition.entriesFor('a\nb\nc\nd');
    expect(entries.map((e) => e.slot.id).toList(), ['m1', 'm2', 'm3', 'm1']);
    expect(entries.map((e) => e.text).toList(), ['a', 'b', 'c', 'd']);
  });

  test('sampleText joins defaults', () {
    final composition = TextComposition(
      slots: const [
        TextCompSlot(id: 't', defaultText: 'TITLE'),
        TextCompSlot(id: 's', defaultText: 'sub'),
      ],
    );
    expect(composition.sampleText, 'TITLE\nsub');
  });
}
