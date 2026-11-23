import 'package:aveditor/l10n/app_localizations.dart';
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

  /// English fallback label (tests / logs). UI should use [localizedLabel].
  final String label;
  final TextStyle Function(TextStyle base) apply;

  String localizedLabel(AppLocalizations l10n) {
    return switch (id) {
      OverlayFonts.defaultId => l10n.overlayFontBasic,
      'jua' => l10n.overlayFontJua,
      'blackHanSans' => l10n.overlayFontBlackHan,
      'bagelFatOne' => l10n.overlayFontBagelFat,
      'songMyung' => l10n.overlayFontSongMyung,
      'hiMelody' => l10n.overlayFontHiMelody,
      'stylish' => l10n.overlayFontStylish,
      'nanumPenScript' => l10n.overlayFontNanumPen,
      'gasoekOne' => l10n.overlayFontGasoek,
      'gaegu' => l10n.overlayFontGaegu,
      'doHyeon' => l10n.overlayFontDoHyeon,
      // Legacy pack ids — still resolvable, rarely shown in the picker.
      'notoSansKr' => l10n.overlayFontNotoSans,
      'gothicA1' => l10n.overlayFontGothicA1,
      'roboto' => l10n.overlayFontRoboto,
      _ => label,
    };
  }
}

class OverlayFonts {
  OverlayFonts._();

  static const defaultId = 'overlay';

  /// Faces shown in the Font menu — display-first Korean Google Fonts.
  static final List<OverlayFontOption> all = [
    OverlayFontOption(
      id: defaultId,
      label: 'Basic',
      apply: (base) => base.copyWith(fontFamily: overlayFontFamily),
    ),
    OverlayFontOption(
      id: 'jua',
      label: 'Jua',
      apply: (base) => GoogleFonts.jua(textStyle: base),
    ),
    OverlayFontOption(
      id: 'blackHanSans',
      label: 'Black Han',
      apply: (base) => GoogleFonts.blackHanSans(textStyle: base),
    ),
    OverlayFontOption(
      id: 'bagelFatOne',
      label: 'Bagel Fat',
      apply: (base) => GoogleFonts.bagelFatOne(textStyle: base),
    ),
    OverlayFontOption(
      id: 'songMyung',
      label: 'Song Myung',
      apply: (base) => GoogleFonts.songMyung(textStyle: base),
    ),
    OverlayFontOption(
      id: 'hiMelody',
      label: 'Hi Melody',
      apply: (base) => GoogleFonts.hiMelody(textStyle: base),
    ),
    OverlayFontOption(
      id: 'stylish',
      label: 'Stylish',
      apply: (base) => GoogleFonts.stylish(textStyle: base),
    ),
    OverlayFontOption(
      id: 'nanumPenScript',
      label: 'Nanum Pen',
      apply: (base) => GoogleFonts.nanumPenScript(textStyle: base),
    ),
    OverlayFontOption(
      id: 'gasoekOne',
      label: 'Gasoek',
      apply: (base) => GoogleFonts.gasoekOne(textStyle: base),
    ),
    OverlayFontOption(
      id: 'gaegu',
      label: 'Gaegu',
      apply: (base) => GoogleFonts.gaegu(
        textStyle: base.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    OverlayFontOption(
      id: 'doHyeon',
      label: 'Do Hyeon',
      apply: (base) => GoogleFonts.doHyeon(textStyle: base),
    ),
  ];

  /// Older pack / project ids kept so [byId] still resolves them.
  static final List<OverlayFontOption> _legacy = [
    OverlayFontOption(
      id: 'notoSansKr',
      label: 'Noto Sans',
      apply: (base) => GoogleFonts.notoSansKr(textStyle: base),
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
    for (final font in _legacy) {
      if (font.id == id) return font;
    }
    return all.first;
  }

  static TextStyle resolve(String? id, TextStyle base) => byId(id).apply(base);

  /// Never throws: offline (or a failed fetch) leaves the platform fallback
  /// face in place, and callers such as pack selection carry on applying the
  /// rest of the style instead of aborting.
  static Future<void> ensureLoaded(String? id) async {
    final option = byId(id);
    if (option.id == defaultId) return;
    try {
      // Warm the Google Fonts registry so CustomPainter / export match preview.
      option.apply(const TextStyle(fontSize: 16));
      await GoogleFonts.pendingFonts();
    } catch (error) {
      debugPrint('OverlayFonts.ensureLoaded($id) failed: $error');
    }
  }
}
