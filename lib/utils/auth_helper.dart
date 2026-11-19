import 'package:aveditor/app_auth_provider.dart';
import 'package:aveditor/config/auth_config.dart';
import 'package:aveditor/models/app_user.dart';
import 'package:aveditor/services/api_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_lib/share_lib_auth.dart';

class AuthHelper {
  /// Opens share_lib [AuthScreen] when needed. Links credits after login.
  static Future<bool> requireAuth(BuildContext context) async {
    final auth = AppAuthProvider.shared;
    if (!auth.isLoggedIn()) {
      if (!context.mounted) return false;
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => ListenableProvider<AuthProvider<AppUser>>.value(
            value: auth,
            child: AuthScreen<AppUser>(config: easyClipAuthConfig),
          ),
          fullscreenDialog: true,
        ),
      );
      if (result != true || !auth.isLoggedIn()) return false;
    }

    await ApiService.shared.ensureAuthToken();
    final token = await auth.getIdToken();
    if (token != null && token.isNotEmpty) {
      await CreditService.instance.linkFirebaseAccount(token);
    }
    return true;
  }
}
