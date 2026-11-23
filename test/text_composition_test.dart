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
