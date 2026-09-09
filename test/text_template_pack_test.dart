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

  test('bundled catalog ships three premium packs with animations', () async {
    final raw = await rootBundle.loadString('assets/text_packs/catalog.json');
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );

    expect(catalog.version, 4);
    expect(catalog.allItems.map((e) => e.id).toList(), [
      'pack_journal',
      'pack_neon_pulse',
      'pack_sticker',
    ]);
    final journal = catalog.itemById('pack_journal')!;
    expect(journal.style.lineBackground?.shape, TextStyleLineShape.brush);
    expect(journal.style.preferredFontId, 'gaegu');
    expect(journal.animation.id, 'typewriter');
  });

  test('pack service loads bundled catalog', () async {
    final service = TextTemplatePackService();
    await service.ensureInitialized();

    expect(service.isReady, isTrue);
    expect(service.itemById('pack_journal')?.title, 'Journal');
    expect(service.styleFor('pack_sticker')?.preferredFontId, 'blackHanSans');
  });
}
