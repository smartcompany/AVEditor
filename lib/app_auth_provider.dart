import 'package:aveditor/models/app_user.dart';
import 'package:aveditor/services/api_service.dart';
import 'package:aveditor/services/credit_service.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/scheduler.dart';
import 'package:share_lib/share_lib_auth.dart';

/// App-wide auth singleton (share_lib AuthProvider).
class AppAuthProvider extends AuthProvider<AppUser> {
  static AppAuthProvider? _instance;

  static AppAuthProvider get shared {
    _instance ??= AppAuthProvider._();
    return _instance!;
  }

  /// Web OAuth client id from google-services.json (client_type 3).
  static const String googleServerClientId =
      '800175376935-iplrsnk5occgmvcf3th8j54vku500too.apps.googleusercontent.com';

  AppAuthProvider._()
      : super(
          firebaseAuth: FirebaseAuth.instance,
          authService: ApiService.shared,
          googleServerClientId: googleServerClientId,
        ) {
    final fbUser = FirebaseAuth.instance.currentUser;
    if (fbUser != null) {
      fbUser.getIdToken().then((token) {
        if (token != null) {
          ApiService.shared.setToken(token);
          CreditService.instance.linkFirebaseAccount(token);
        }
      });
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      initialize();
    });
  }
}
