import 'package:aveditor/models/text_overlay_style.dart';
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
}
