import 'dart:convert';

import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('bundled catalog ships effects and templates', () async {
    final raw = await rootBundle.loadString('assets/text_packs/catalog.json');
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );

    expect(catalog.version, 6);
    expect(catalog.allItems.map((e) => e.id).toList(), [
      'effect_pop_green',
      'effect_pastel',
      'effect_torn_label',
      'pack_journal',
      'pack_neon_pulse',
      'pack_sticker',
    ]);
    final pop = catalog.itemById('effect_pop_green')!;
    expect(pop.kind, 'effect');
    expect(pop.animation.isNone, isTrue);
    expect(pop.style.strokes.length, 2);

    final pastel = catalog.itemById('effect_pastel')!;
    expect(pastel.style.fillGradient?.colorArgb.length, 3);

    final torn = catalog.itemById('effect_torn_label')!;
    expect(torn.style.lineBackground?.shape, TextStyleLineShape.brush);

    final journal = catalog.itemById('pack_journal')!;
    expect(journal.kind, 'template');
    expect(journal.animation.id, 'typewriter');
    expect(journal.animation.durationMs, 900);
    expect(journal.style.preferredFontId, 'gaegu');

    final neon = catalog.itemById('pack_neon_pulse')!;
    expect(neon.kind, 'template');
    expect(neon.animation.id, 'fade');

    final sticker = catalog.itemById('pack_sticker')!;
    expect(sticker.kind, 'template');
    expect(sticker.animation.id, 'slide_up');
  });

  test('pack service loads bundled effect and template catalog', () async {
    final service = TextTemplatePackService();
    await service.ensureInitialized();

    expect(service.isReady, isTrue);
    expect(service.itemById('effect_pop_green')?.title, 'Pop');
    expect(service.styleFor('effect_pastel')?.fillGradient, isNotNull);
    expect(service.itemById('pack_journal')?.kind, 'template');
    expect(service.itemById('pack_sticker')?.animation.id, 'slide_up');
  });
}
