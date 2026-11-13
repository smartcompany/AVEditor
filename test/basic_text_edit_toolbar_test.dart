import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/widgets/basic_text_edit_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ValueNotifier<TextOverlay>> pumpToolbar(WidgetTester tester) async {
    final overlay = ValueNotifier(
      TextOverlay(
        text: 'Hi',
        start: Duration.zero,
        end: const Duration(seconds: 2),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ValueListenableBuilder<TextOverlay>(
              valueListenable: overlay,
              builder: (context, value, _) => BasicTextEditToolbar(
                overlay: value,
                onChanged: (next) => overlay.value = next,
              ),
            ),
          ),
        ),
      ),
    );
    return overlay;
  }

  testWidgets('font tab reads "Aa" and has no captions', (tester) async {
    await pumpToolbar(tester);
    expect(find.text('Aa'), findsOneWidget);
    for (final caption in ['Font', 'Style', 'Align', 'Color']) {
      expect(find.text(caption), findsNothing, reason: caption);
    }
  });

  Finder colorSwatch() => find
      .byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
            (w.decoration! as BoxDecoration).color == Colors.white,
      )
      .first;

  Finder colorTab() =>
      find.ancestor(of: colorSwatch(), matching: find.byType(InkWell)).first;

  final sizeTrack = find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_FontSizeTrackPainter',
  );

  testWidgets('size tab is selected first and drives the size bar', (
    tester,
  ) async {
    final overlay = await pumpToolbar(tester);
    // The number is hidden at rest and floats above the thumb mid-drag.
    expect(find.text('84'), findsNothing);
    final gesture = await tester.startGesture(tester.getCenter(sizeTrack));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(overlay.value.fontSize, greaterThan(84));
    expect(find.text('${overlay.value.fontSize.round()}'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(find.text('${overlay.value.fontSize.round()}'), findsNothing);
  });

  testWidgets('size, font and color tabs swap the right side', (tester) async {
    await pumpToolbar(tester);
    final customColor = find.bySemanticsLabel('Custom color');
    final fontList = find.text('Basic');

    await tester.tap(find.text('Aa'));
    await tester.pumpAndSettle();
    expect(fontList, findsOneWidget);
    expect(sizeTrack, findsNothing);

    await tester.tap(colorTab());
    await tester.pumpAndSettle();
    expect(customColor, findsOneWidget);
    expect(fontList, findsNothing);

    // Style and align act without changing the selected tab.
    await tester.tap(find.byIcon(Icons.format_align_center));
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();
    expect(customColor, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('basic-text-size-tab')));
    await tester.pumpAndSettle();
    expect(sizeTrack, findsOneWidget);
  });

  testWidgets('right area stays usable on a 375pt-wide phone', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpToolbar(tester);
    // The test font (Ahem) is far wider than real fonts, so only check that
    // nothing overflows and the size bar keeps real width. On a device the
    // track measured ~148pt at 375pt wide.
    expect(tester.takeException(), isNull);
    expect(tester.getSize(sizeTrack).width, greaterThan(100));
  });

  testWidgets('style button cycles and shows a cycle badge', (tester) async {
    final overlay = await pumpToolbar(tester);
    final badge = find.byIcon(Icons.sync);
    expect(badge, findsOneWidget);
    await tester.tap(badge);
    await tester.pump();
    expect(overlay.value.style, TextOverlayStyle.plain.next);
  });

  testWidgets('custom color button opens a picker that sets any color', (
    tester,
  ) async {
    final overlay = await pumpToolbar(tester);
    await tester.tap(colorTab());
    await tester.pumpAndSettle();
    final custom = find.bySemanticsLabel('Custom color');
    await tester.ensureVisible(custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);

    // Drag the hue bar to the middle → a cyan-ish hue no palette swatch has.
    final hue = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint && w.painter.runtimeType.toString() == '_HuePainter',
    );
    await tester.tapAt(tester.getCenter(hue));
    await tester.pump();
    final picked = HSVColor.fromColor(overlay.value.color);
    expect(picked.hue, closeTo(180, 20));
    expect(
      BasicTextEditToolbar.colors.map((c) => c.toARGB32()),
      isNot(contains(overlay.value.color.toARGB32())),
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsNothing);
  });
}
