import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/widgets/basic_text_edit_toolbar.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
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

  testWidgets('toolbar shows Font and keeps size control without Tt', (
    tester,
  ) async {
    await pumpToolbar(tester);
    expect(find.text('Font'), findsOneWidget);
    expect(find.text('Aa'), findsNothing);
    expect(find.text('TT'), findsNothing);
    expect(find.text('Tt'), findsNothing);
    for (final caption in ['Style', 'Align', 'Color']) {
      expect(find.text(caption), findsNothing, reason: caption);
    }
  });

  Finder colorTab() => find.byKey(const ValueKey('basic-text-color-button'));

  final sizeTrack = find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_FontSizeTrackPainter',
  );

  testWidgets('size slider is always on the bar', (tester) async {
    final overlay = await pumpToolbar(tester);
    expect(sizeTrack, findsOneWidget);
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

  testWidgets('color opens a submenu that closes after a pick', (tester) async {
    final overlay = await pumpToolbar(tester);
    expect(sizeTrack, findsOneWidget);

    await tester.tap(colorTab());
    await tester.pump();
    // Submenu replaces the size slider for the duration of the pick.
    expect(sizeTrack, findsNothing);
    expect(find.bySemanticsLabel('Custom color'), findsOneWidget);

    // Pick black from the palette — submenu collapses, size returns.
    final black = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration! as BoxDecoration).color == Colors.black,
    );
    await tester.tap(black.first);
    await tester.pump();
    expect(overlay.value.color.toARGB32(), Colors.black.toARGB32());
    expect(find.bySemanticsLabel('Custom color'), findsNothing);
    expect(sizeTrack, findsOneWidget);
  });

  testWidgets('right area stays usable on a 375pt-wide phone', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpToolbar(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(sizeTrack).width, greaterThan(60));
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
    expect(sizeTrack, findsOneWidget);
  });

  testWidgets('Font opens a submenu that closes after a pick', (tester) async {
    final overlay = await pumpToolbar(tester);
    await tester.tap(find.byKey(const ValueKey('basic-text-font-button')));
    await tester.pump();
    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Jua'), findsOneWidget);
    expect(sizeTrack, findsNothing);

    await tester.tap(find.text('Jua'));
    await tester.pump();
    expect(overlay.value.fontFamily, OverlayFonts.all[1].id);
    // Submenu dismissed after selection — main bar returns.
    expect(find.text('Jua'), findsNothing);
    expect(find.text('Basic'), findsNothing);
    expect(find.text('Font'), findsOneWidget);
    expect(sizeTrack, findsOneWidget);
  });
}
