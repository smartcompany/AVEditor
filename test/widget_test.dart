import 'package:aveditor/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App launches home screen', (tester) async {
    await tester.pumpWidget(const AveditorApp());
    await tester.pumpAndSettle();
    expect(find.text('AVEditor'), findsOneWidget);
  });
}
