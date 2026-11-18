import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/navigation/app_navigator.dart';
import 'package:aveditor/screens/home_screen.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:aveditor/services/retention_notification_service.dart';
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
      navigatorKey: AppNavigator.key,
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
  unawaited(AnalyticsService.instance.init());
  // Deliver queued events when the app leaves the foreground.
  AppLifecycleListener(
    onHide: () => unawaited(AnalyticsService.instance.flush()),
  );
  // Asset reads started before the first frame stay pending, and later
  // opens of the transition panel wait on that same read.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(TextTemplatePackService.instance.ensureInitialized());
    unawaited(TransitionCatalogService.instance.ensureInitialized());
    unawaited(_initRetentionPush());
    unawaited(_initMonetization());
  });
}

Future<void> _initRetentionPush() async {
  final push = RetentionNotificationService.instance;
  await push.ensureInitialized();
  push.onNotificationTap = (payload) {
    unawaited(AppNavigator.handleRetentionPayload(payload));
  };
  final launch = push.launchPayload;
  if (launch != null) {
    // Wait a frame so [navigatorKey] is attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(AppNavigator.handleRetentionPayload(launch));
    });
  }
  // After catalogs load, seed / detect new asset versions (priority 3).
  unawaited(_watchCatalogDrops());
}

Future<void> _watchCatalogDrops() async {
  final transitions = TransitionCatalogService.instance;
  final texts = TextTemplatePackService.instance;
  await Future.wait([
    transitions.ensureInitialized(),
    texts.ensureInitialized(),
  ]);

  Future<void> publish() async {
    final ctx = AppNavigator.key.currentContext;
    final l10n = ctx == null ? null : AppLocalizations.of(ctx);
    await RetentionNotificationService.instance.onCatalogVersions(
      transitionVersion: transitions.catalog.version,
      textPackVersion: texts.catalog.version,
      title: l10n?.pushCatalogTitle ?? 'New editing tools',
      body: l10n?.pushCatalogBody ??
          'Fresh transitions and text styles just landed.',
    );
  }

  await publish();
  transitions.addListener(() => unawaited(publish()));
  texts.addListener(() => unawaited(publish()));
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
