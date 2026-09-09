import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Curated fonts for basic (Shorts-style) text editing.
class OverlayFontOption {
  const OverlayFontOption({
    required this.id,
    required this.label,
    required this.apply,
  });

  final String id;
  final String label;
  final TextStyle Function(TextStyle base) apply;
}

class OverlayFonts {
  OverlayFonts._();

  static const defaultId = 'overlay';

  static final List<OverlayFontOption> all = [
    OverlayFontOption(
      id: defaultId,
      label: 'Basic',
      apply: (base) => base.copyWith(fontFamily: overlayFontFamily),
    ),
    OverlayFontOption(
      id: 'notoSansKr',
      label: 'Noto Sans',
      apply: (base) => GoogleFonts.notoSansKr(textStyle: base),
    ),
    OverlayFontOption(
      id: 'gaegu',
      label: 'Gaegu',
      apply: (base) => GoogleFonts.gaegu(
        textStyle: base.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    OverlayFontOption(
      id: 'blackHanSans',
      label: 'Black Han',
      apply: (base) => GoogleFonts.blackHanSans(textStyle: base),
    ),
    OverlayFontOption(
      id: 'doHyeon',
      label: 'Do Hyeon',
      apply: (base) => GoogleFonts.doHyeon(textStyle: base),
    ),
    OverlayFontOption(
      id: 'gothicA1',
      label: 'Gothic A1',
      apply: (base) => GoogleFonts.gothicA1(textStyle: base),
    ),
    OverlayFontOption(
      id: 'roboto',
      label: 'Roboto',
      apply: (base) => GoogleFonts.roboto(textStyle: base),
    ),
  ];

  static OverlayFontOption byId(String? id) {
    for (final font in all) {
      if (font.id == id) return font;
    }
    return all.first;
  }

  static TextStyle resolve(String? id, TextStyle base) => byId(id).apply(base);

  static Future<void> ensureLoaded(String? id) async {
    final option = byId(id);
    if (option.id == defaultId) return;
    // Warm the Google Fonts registry so CustomPainter / export match preview.
    option.apply(const TextStyle(fontSize: 16));
    await GoogleFonts.pendingFonts();
  }
}
