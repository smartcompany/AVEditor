import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Google OAuth for YouTube Data API (youtube.upload scope).
class YouTubeAuthService {
  YouTubeAuthService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _refreshTokenKey = 'youtube_refresh_token';

  final FlutterSecureStorage _storage;

  Future<bool> get isSignedIn async {
    final token = await _storage.read(key: _refreshTokenKey);
    return token != null && token.isNotEmpty;
  }

  Future<void> signIn() async {
    // TODO: Google OAuth PKCE — iOS / Android / macOS client IDs
    throw UnimplementedError('YouTube sign-in not implemented yet');
  }

  Future<void> signOut() async {
    await _storage.delete(key: _refreshTokenKey);
  }
}
