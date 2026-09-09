import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TextOverlayStyle cycles through all modes', () {
    var style = TextOverlayStyle.plain;
    style = style.next;
    expect(style, TextOverlayStyle.outline);
    style = style.next;
    expect(style, TextOverlayStyle.box);
    style = style.next;
    expect(style, TextOverlayStyle.boxDim);
    style = style.next;
    expect(style, TextOverlayStyle.plain);
  });

  test('TextOverlayStyle.fromJson falls back to plain', () {
    expect(TextOverlayStyle.fromJson('outline'), TextOverlayStyle.outline);
    expect(TextOverlayStyle.fromJson('missing'), TextOverlayStyle.plain);
    expect(TextOverlayStyle.fromJson(null), TextOverlayStyle.plain);
  });

  test('TextStyleTemplate round-trips through JSON including brush + font', () {
    const original = TextStyleTemplate(
      id: 'pack_journal',
      label: 'Journal',
      fillArgb: 0xFF2A1810,
      fillUseAccent: false,
      preferredFontId: 'gaegu',
      lineBackground: TextStyleLineBackground(
        useAccent: false,
        colorArgb: 0xFFF2E4CC,
        shape: TextStyleLineShape.brush,
        shadowOpacity: 0.55,
        shadowBlurFactor: 0.28,
      ),
    );
    final restored = TextStyleTemplate.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.preferredFontId, 'gaegu');
    expect(restored.lineBackground?.shape, TextStyleLineShape.brush);
    expect(restored.lineBackground?.shadowOpacity, 0.55);
  });

  test('built-in Word Art catalog is empty (server-driven packs)', () {
    expect(TextStyleTemplateCatalog.all, isEmpty);
  });

  test('basic style templates still resolve for Shorts A-cycle', () {
    expect(TextStyleTemplateCatalog.byId('classic')?.id, 'classic');
    expect(TextStyleTemplateCatalog.byId('outline')?.id, 'outline');
    expect(resolveOverlayTemplate(TextOverlay(
      text: 'hi',
      start: Duration.zero,
      end: const Duration(seconds: 1),
    )).id, 'classic');
  });

  test('copyWith can clear templateId', () {
    final overlay = TextOverlay(
      text: 'hi',
      start: Duration.zero,
      end: const Duration(seconds: 2),
      templateId: 'outline',
    );

    final cleared = overlay.copyWith(templateId: null);
    expect(cleared.templateId, isNull);
    expect(resolveOverlayTemplate(cleared).id, 'classic');
  });
}
