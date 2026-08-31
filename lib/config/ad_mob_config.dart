/// AdMob app IDs (share_lib / google_mobile_ads).
///
/// Must match native config:
/// - iOS: `GADApplicationIdentifier` in Info.plist
/// - Android: `com.google.android.gms.ads.APPLICATION_ID` in AndroidManifest
///
/// Defaults are Google sample app IDs (same as other apps in this workspace).
abstract final class AdMobConfig {
  static const iosApplicationId = String.fromEnvironment(
    'ADMOB_IOS_APP_ID',
    defaultValue: 'ca-app-pub-3940256099942544~1458002511',
  );

  static const androidApplicationId = String.fromEnvironment(
    'ADMOB_ANDROID_APP_ID',
    defaultValue: 'ca-app-pub-3940256099942544~3347511713',
  );
}
