// Generated-style Firebase options for project aveditor-shorts.
// Source: GoogleService-Info.plist / google-services.json

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Firebase web is not configured for EasyClip.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDmHagy2wx7fMjvKQ4fwJF3svwSZX_-YsM',
    appId: '1:800175376935:ios:a57760be8dfe57c5979c02',
    messagingSenderId: '800175376935',
    projectId: 'aveditor-shorts',
    storageBucket: 'aveditor-shorts.firebasestorage.app',
    iosBundleId: 'com.smartcompany.aveditor',
    iosClientId:
        '800175376935-qjqsbkpr85m7h3rnga534edqqkjg6b8u.apps.googleusercontent.com',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAhwXz-FTRkvwAanL0iHjwzcg9TE1IgxcM',
    appId: '1:800175376935:android:0d3eafd2cd129c90979c02',
    messagingSenderId: '800175376935',
    projectId: 'aveditor-shorts',
    storageBucket: 'aveditor-shorts.firebasestorage.app',
  );
}
