import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// TikTok sign-in failed or was closed.
class TikTokAuthException implements Exception {
  const TikTokAuthException(this.code, [this.message = '']);

  /// `cancelled`, `server_not_configured`, `access_denied`, TikTok OAuth
  /// error codes, or `network`.
  final String code;
  final String message;

  @override
  String toString() => 'TikTokAuthException($code $message)';
}

class TikTokSession {
  const TikTokSession({
    required this.accessToken,
    required this.refreshToken,
    required this.openId,
    required this.expiresAt,
    required this.refreshExpiresAt,
    required this.scope,
  });

  factory TikTokSession.fromTokenJson(Map<String, dynamic> json, DateTime now) {
    int seconds(Object? value) =>
        value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    return TikTokSession(
      accessToken: '${json['access_token'] ?? ''}',
      refreshToken: '${json['refresh_token'] ?? ''}',
      openId: '${json['open_id'] ?? ''}',
      expiresAt: now.add(Duration(seconds: seconds(json['expires_in']))),
      refreshExpiresAt: now.add(
        Duration(seconds: seconds(json['refresh_expires_in'])),
      ),
      scope: '${json['scope'] ?? ''}',
    );
  }

  factory TikTokSession.fromStorage(Map<String, dynamic> json) {
    return TikTokSession(
      accessToken: '${json['accessToken']}',
      refreshToken: '${json['refreshToken']}',
      openId: '${json['openId']}',
      expiresAt: DateTime.parse('${json['expiresAt']}'),
      refreshExpiresAt: DateTime.parse('${json['refreshExpiresAt']}'),
      scope: '${json['scope'] ?? ''}',
    );
  }

  final String accessToken;
  final String refreshToken;
  final String openId;
  final DateTime expiresAt;
  final DateTime refreshExpiresAt;
  final String scope;

  /// TikTok returns granted scopes comma-separated; accept spaces too.
  bool get canPublish =>
      scope.split(RegExp(r'[,\s]+')).contains('video.publish');

  Map<String, dynamic> toStorage() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'openId': openId,
    'expiresAt': expiresAt.toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt.toIso8601String(),
    'scope': scope,
  };
}

/// TikTok Login Kit (web flow in a system auth session) for Direct Post.
///
/// The server (`/api/tiktok/*`) holds the client secret and swaps the OAuth
/// code for user tokens. TikTok redirects to `/tiktok/callback`, which bounces
/// to `easyclipshare://tiktok/callback?code=…` and ends the auth session.
class TikTokAuthService {
  TikTokAuthService({
    http.Client? client,
    FlutterSecureStorage? storage,
    this.serverBase = 'https://aveditorserver.vercel.app',
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage();

  static const callbackScheme = 'easyclipshare';
  static const _storageKey = 'tiktok_session_v1';

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final String serverBase;

  /// Saved session, refreshed when the access token is about to expire.
  /// Null when nobody is signed in or the refresh token has expired.
  Future<TikTokSession?> currentSession() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return null;
    TikTokSession session;
    try {
      session = TikTokSession.fromStorage(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      await signOut();
      return null;
    }
    final now = DateTime.now();
    if (session.expiresAt.isAfter(now.add(const Duration(minutes: 5)))) {
      return session;
    }
    if (session.refreshExpiresAt.isBefore(now)) {
      await signOut();
      return null;
    }
    try {
      final refreshed = await _token({'refresh_token': session.refreshToken});
      await _save(refreshed);
      return refreshed;
    } catch (error) {
      debugPrint('[TikTokAuth] 토큰 갱신 실패: $error');
      await signOut();
      return null;
    }
  }

  /// Opens TikTok's sign-in page. [freshAccount] avoids reusing the browser
  /// session so another account can be chosen.
  Future<TikTokSession> signIn({bool freshAccount = false}) async {
    final config = await _config();
    final state = _randomState();
    final authorize = Uri.https('www.tiktok.com', '/v2/auth/authorize/', {
      'client_key': config.clientKey,
      'scope': config.scopes.join(','),
      'response_type': 'code',
      'redirect_uri': config.redirectUri,
      'state': state,
      if (freshAccount) 'disable_auto_auth': '1',
    });
    final String result;
    try {
      result = await FlutterWebAuth2.authenticate(
        url: authorize.toString(),
        callbackUrlScheme: callbackScheme,
        options: FlutterWebAuth2Options(preferEphemeral: freshAccount),
      );
    } on Exception catch (error) {
      final text = '$error'.toLowerCase();
      if (text.contains('cancel')) throw const TikTokAuthException('cancelled');
      throw TikTokAuthException('network', '$error');
    }
    final params = Uri.parse(result).queryParameters;
    final error = params['error'];
    if (error != null) {
      throw TikTokAuthException(error, params['error_description'] ?? '');
    }
    if (params['state'] != state) {
      throw const TikTokAuthException('state_mismatch');
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const TikTokAuthException('missing_code');
    }
    final session = await _token({'code': code});
    debugPrint('[TikTokAuth] granted scope="${session.scope}"');
    if (!session.canPublish) {
      // Shown in the error dialog so a missing scope is easy to spot.
      throw TikTokAuthException('access_denied', 'granted: ${session.scope}');
    }
    await _save(session);
    return session;
  }

  Future<void> signOut() => _storage.delete(key: _storageKey);

  Future<void> _save(TikTokSession session) =>
      _storage.write(key: _storageKey, value: jsonEncode(session.toStorage()));

  Future<({String clientKey, String redirectUri, List<String> scopes})>
  _config() async {
    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$serverBase/api/tiktok/config'));
    } catch (error) {
      throw TikTokAuthException('network', '$error');
    }
    if (res.statusCode != 200) {
      throw const TikTokAuthException('server_not_configured');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      clientKey: '${json['client_key']}',
      redirectUri: '${json['redirect_uri']}',
      scopes: [for (final s in (json['scopes'] as List? ?? const [])) '$s'],
    );
  }

  Future<TikTokSession> _token(Map<String, String> body) async {
    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse('$serverBase/api/tiktok/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (error) {
      throw TikTokAuthException('network', '$error');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200 || json['access_token'] == null) {
      throw TikTokAuthException(
        '${json['error'] ?? 'token_exchange_failed'}',
        '${json['error_description'] ?? ''}',
      );
    }
    return TikTokSession.fromTokenJson(json, DateTime.now());
  }

  String _randomState() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(16, (_) => random.nextInt(256)));
  }
}
