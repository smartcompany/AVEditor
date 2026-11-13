import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/screens/home_screen.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:share_lib/share_lib.dart';

/// Serves `/api/settings` (ad rotation + unit ids) for share_lib's AdService.
const _settingsBaseUrl = 'https://aveditorserver.vercel.app';

class AveditorApp extends StatelessWidget {
  const AveditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeScreen(),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const AveditorApp());
  // Asset reads started before the first frame stay pending, and later
  // opens of the transition panel wait on that same read.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(TextTemplatePackService.instance.ensureInitialized());
    unawaited(TransitionCatalogService.instance.ensureInitialized());
    unawaited(_initMonetization());
  });
}

/// Subscription state first; ads are only prepared for free users, since
/// they are only shown to unlock Pro items for a single export.
Future<void> _initMonetization() async {
  await ProService.instance.ensureInitialized();
  try {
    await MobileAds.instance.initialize();
    AdService.shared.setBaseUrl(_settingsBaseUrl);
    final hasAds = await AdService.shared.loadSettings();
    if (hasAds && !ProService.instance.isPro) {
      unawaited(AdService.shared.preloadAd());
    }
  } catch (e) {
    debugPrint('[monetization] ad setup failed: $e');
  }
}
