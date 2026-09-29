import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google OAuth for YouTube Data API (`youtube.upload`).
///
/// The iOS client id belongs to Firebase project `aveditor-shorts`
/// (bundle `com.smart.aveditor`). Android matches package
/// `com.smart.aveditor` plus the debug SHA registered on that app.
class YouTubeAuthService {
  YouTubeAuthService({FlutterSecureStorage? storage, GoogleSignIn? google})
    : _storage = storage ?? const FlutterSecureStorage(),
      _google = google ?? _defaultGoogle();

  static const uploadScope = 'https://www.googleapis.com/auth/youtube.upload';

  /// Playlists and age restriction use `videos.update` / `playlistItems.insert`,
  /// which are not covered by [uploadScope].
  static const accountScope = 'https://www.googleapis.com/auth/youtube';

  /// `email` and `profile` are requested by Google Sign-In itself.
  /// Restoring a previous session does not add [uploadScope], so callers
  /// must go through [accessToken], which asks for it.
  static const scopes = <String>[uploadScope];

  /// Public iOS OAuth client. Override with `--dart-define=YOUTUBE_IOS_CLIENT_ID`.
  static const iosClientId = String.fromEnvironment(
    'YOUTUBE_IOS_CLIENT_ID',
    defaultValue:
        '800175376935-vqq6ec0uj9eegi40780rud4lrdvnm2bn.apps.googleusercontent.com',
  );

  static const _sessionKey = 'youtube_signed_in';

  final FlutterSecureStorage _storage;
  final GoogleSignIn _google;

  static GoogleSignIn _defaultGoogle() {
    final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return GoogleSignIn(clientId: ios ? iosClientId : null, scopes: scopes);
  }

  Future<bool> get isSignedIn async {
    if (_needsIosClient) return false;
    try {
      final account = _google.currentUser ?? await _google.signInSilently();
      if (account != null) return true;
    } catch (error, stack) {
      debugPrint('YouTubeAuthService.isSignedIn failed: $error\n$stack');
    }
    final marker = await _storage.read(key: _sessionKey);
    return marker == '1';
  }

  Future<void> signIn() async {
    if (_needsIosClient) {
      throw StateError(
        'iOS YouTube client ID is missing. Rebuild with '
        'YOUTUBE_IOS_CLIENT_ID.',
      );
    }
    final account = await _google.signIn();
    if (account == null) {
      throw StateError('YouTube sign-in was cancelled');
    }
    await _ensureUploadScope();
    final auth = await account.authentication;
    if (auth.accessToken == null || auth.accessToken!.isEmpty) {
      throw StateError('YouTube access token was not issued');
    }
    await _storage.write(key: _sessionKey, value: '1');
  }

  /// Fresh access token for `videos.insert`. Google Sign-In refreshes it.
  Future<String> accessToken() async {
    final account = _google.currentUser ?? await _google.signInSilently();
    if (account == null) {
      throw StateError('YouTube sign-in required');
    }
    await _ensureUploadScope();
    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('YouTube access token was not issued');
    }
    return token;
  }

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (error, stack) {
      debugPrint('YouTubeAuthService.signOut failed: $error\n$stack');
    }
    await _storage.delete(key: _sessionKey);
  }

  /// Asks for channel management when the upload needs a playlist or an
  /// age restriction. Call from a tap, then read [accessToken] again.
  Future<void> ensureAccountScope() {
    return _requestScope(accountScope, label: '재생목록·연령제한');
  }

  /// Silent sign-in restores the old grant. `videos.insert` needs a token
  /// that includes [uploadScope], so ask again when it is missing.
  Future<void> _ensureUploadScope() {
    return _requestScope(uploadScope, label: 'youtube.upload');
  }

  Future<void> _requestScope(String scope, {required String label}) async {
    debugPrint('[YouTubeUpload] $label 권한 요청');
    final granted = await _google.requestScopes(<String>[scope]);
    debugPrint(
      granted ? '[YouTubeUpload] $label 권한 허용' : '[YouTubeUpload] $label 권한 거부',
    );
    if (!granted) {
      throw StateError('YouTube permission was not granted ($label)');
    }
  }

  bool get _needsIosClient =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      iosClientId.isEmpty;
}
