import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/material.dart';
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

  test('TextStyleTemplate round-trips through JSON', () {
    final original = TextStyleTemplateCatalog.neon;
    final restored = TextStyleTemplate.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.label, original.label);
    expect(restored.strokes.length, original.strokes.length);
    expect(restored.glow?.blurFactor, original.glow?.blurFactor);
  });

  test('catalog lookup and overlay template persistence', () {
    final overlay = TextOverlay(
      text: 'hi',
      start: Duration.zero,
      end: const Duration(seconds: 2),
      templateId: 'comic',
    );

    expect(overlay.template?.id, 'comic');
    expect(resolveOverlayTemplate(overlay).id, 'comic');

    final json = overlay.toJson();
    final loaded = TextOverlay.fromJson(json);
    expect(loaded.templateId, 'comic');
    expect(loaded.template?.label, 'Comic');
  });

  test('copyWith can clear templateId', () {
    final overlay = TextOverlay(
      text: 'hi',
      start: Duration.zero,
      end: const Duration(seconds: 2),
      templateId: 'neon',
    );

    final cleared = overlay.copyWith(templateId: null);
    expect(cleared.templateId, isNull);
    expect(resolveOverlayTemplate(cleared).id, 'classic');
  });
}
