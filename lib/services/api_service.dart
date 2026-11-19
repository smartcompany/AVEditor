import 'dart:convert';

import 'package:aveditor/models/app_user.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:share_lib/share_lib_auth.dart';

/// Backend client for auth + credits. Implements share_lib [AuthServiceInterface].
class ApiService implements AuthServiceInterface {
  ApiService._();

  static final ApiService shared = ApiService._();

  static String get baseUrl => CreditService.baseUrl;

  String? _token;

  /// Current Firebase ID token (Bearer), if [ensureAuthToken] succeeded.
  String? get token => _token;

  @override
  void setToken(String token) {
    _token = token;
  }

  Future<bool> ensureAuthToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _token = null;
      return false;
    }
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) {
        _token = null;
        return false;
      }
      _token = token;
      return true;
    } catch (e) {
      debugPrint('[ApiService] ensureAuthToken failed: $e');
      return _token != null;
    }
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (_token != null && _token!.isNotEmpty)
          'Authorization': 'Bearer $_token',
      };

  static String _utf8Body(http.Response response) =>
      utf8.decode(response.bodyBytes);

  @override
  Future<AppUser?> getCurrentUser() async {
    await ensureAuthToken();
    if (_token == null) return null;
    final response = await http.get(
      Uri.parse('$baseUrl/api/users/me'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      debugPrint('[ApiService] getCurrentUser ${response.statusCode}');
      // Still return a minimal user from Firebase so login can complete
      // before the users/me endpoint is fully configured.
      final fb = FirebaseAuth.instance.currentUser;
      if (fb == null) return null;
      return AppUser(
        id: fb.uid,
        displayName: fb.displayName,
        email: fb.email,
        photoUrl: fb.photoURL,
      );
    }
    final data = jsonDecode(_utf8Body(response)) as Map<String, dynamic>;
    return AppUser.fromJson(data);
  }

  @override
  Future<Map<String, String>> loginWithKakao(String accessToken) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/auth/kakao/firebase'),
      headers: _headers,
      body: jsonEncode({'access_token': accessToken}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to login with Kakao: ${response.statusCode} ${_utf8Body(response)}',
      );
    }
    final data = jsonDecode(_utf8Body(response)) as Map<String, dynamic>;
    final result = <String, String>{
      'uid': data['uid'] as String,
      'kakao_id': data['kakao_id'] as String,
    };
    final custom = data['custom_token'] as String?;
    if (custom != null && custom.isNotEmpty) {
      result['custom_token'] = custom;
    }
    return result;
  }
}
