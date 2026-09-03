import 'dart:convert';

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

  test('bundled catalog parses and exposes pack styles', () async {
    final raw = await rootBundle.loadString('assets/text_packs/catalog.json');
    final catalog = TextTemplatePackCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );

    expect(catalog.categories, isNotEmpty);
    final hearts = catalog.itemById('pack_hearts');
    expect(hearts, isNotNull);
    expect(hearts!.hasLottie, isTrue);
    expect(hearts.style.glow, isNotNull);
  });

  test('pack service loads bundled catalog', () async {
    final service = TextTemplatePackService();
    await service.ensureInitialized();

    expect(service.isReady, isTrue);
    expect(service.itemById('pack_burst')?.title, 'BAM');
    expect(service.isInstalled(service.itemById('pack_burst')!), isTrue);
    expect(service.styleFor('pack_torn')?.lineBackground, isNotNull);
  });
}
