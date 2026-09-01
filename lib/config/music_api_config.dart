/// Optional third-party music catalog credentials.
///
/// Register a free client id at https://devportal.jamendo.com and pass it at
/// build time:
///
/// `flutter run --dart-define=JAMENDO_CLIENT_ID=your_id`
class MusicApiConfig {
  const MusicApiConfig._();

  static const jamendoClientId = String.fromEnvironment(
    'JAMENDO_CLIENT_ID',
    defaultValue: '',
  );

  static bool get hasJamendoCatalog => jamendoClientId.isNotEmpty;
}
