import 'dart:convert';

import 'package:aveditor/models/text_entrance_animation.dart';
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

  test('bundled catalog ships effects and CapCut templates', () async {
    final raw = await rootBundle.loadString('assets/text_packs/catalog.json');
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );

    expect(catalog.version, greaterThanOrEqualTo(19));
    final effects = catalog.allItems.where((e) => e.kind == 'effect').toList();
    final templates =
        catalog.allItems.where((e) => e.kind == 'template').toList();
    expect(effects, hasLength(50));
    // Journal + Star Crawl + Credits + CapCut 30.
    expect(templates, hasLength(33));
    expect(effects.take(3).map((e) => e.id), [
      'effect_pop_green',
      'effect_pastel',
      'effect_torn_label',
    ]);
    expect(templates.first.id, 'pack_journal');
    expect(
      templates.map((e) => e.id),
      containsAll([
        'pack_journal',
        'tpl_star_wars_crawl',
        'tpl_credits_scroll',
        'tpl_pop_up',
        'tpl_typewriter',
        'tpl_glitch',
        'tpl_neon',
      ]),
    );
    final ids = catalog.allItems.map((e) => e.id).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: 'ids are unique');
    const fonts = {
      'notoSansKr',
      'gaegu',
      'blackHanSans',
      'doHyeon',
      'gothicA1',
      'roboto',
    };
    for (final item in catalog.allItems) {
      expect(fonts, contains(item.style.preferredFontId), reason: item.id);
      if (item.kind == 'effect') {
        expect(item.animation.isNone, isTrue, reason: item.id);
      } else {
        expect(
          TextEntranceIds.all,
          contains(item.animation.id),
          reason: item.id,
        );
      }
    }
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
    expect(journal.animation.staggerBy, 'line');
    expect(journal.layout.perLine, isTrue);
    expect(journal.layout.lineGapFactor, 0.12);
    expect(journal.style.preferredFontId, 'gaegu');
    expect(journal.style.lineBackground?.hasUnderlayImage, isTrue);
    expect(
      journal.style.lineBackground?.underlayAsset,
      'text_packs/journal/paper_a.png',
    );

    final popUp = catalog.itemById('tpl_pop_up')!;
    expect(popUp.animation.id, 'pop');
    expect(popUp.animation.bounce, greaterThan(0));

    final crawl = catalog.itemById('tpl_star_wars_crawl')!;
    expect(crawl.animation.id, 'crawl');

    final chat = catalog.itemById('tpl_chat_message')!;
    expect(chat.composition?.repeatSlots, isTrue);
    expect(chat.composition!.slots, hasLength(2));
    expect(
      chat.composition!.entriesFor('a\nb\nc\nd').map((e) => e.slot.id),
      ['m1', 'm2', 'm1', 'm2'],
    );
  });

  test('pack service loads bundled effect and template catalog', () async {
    final service = TextTemplatePackService();
    await service.ensureInitialized();

    expect(service.isReady, isTrue);
    expect(service.itemById('effect_pop_green')?.title, 'Pop');
    expect(service.styleFor('effect_pastel')?.fillGradient, isNotNull);
    expect(service.itemById('pack_journal')?.kind, 'template');
    expect(service.itemById('tpl_pop_up')?.animation.id, 'pop');
    expect(service.itemById('tpl_neon')?.animation.id, 'neon');
  });
}
