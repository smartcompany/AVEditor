#!/usr/bin/env python3
"""Generate lib/firebase_options.dart from native Firebase config files.

Reads:
  - ios/Runner/GoogleService-Info.plist
  - android/app/google-services.json

These native files stay local (gitignored). Do not commit the generated
firebase_options.dart — it contains Google API keys that GitHub secret
scanning flags.
"""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "ios" / "Runner" / "GoogleService-Info.plist"
GSERVICES = ROOT / "android" / "app" / "google-services.json"
OUT = ROOT / "lib" / "firebase_options.dart"


def load_ios() -> dict[str, str]:
    if not PLIST.is_file():
        raise SystemExit(f"Missing {PLIST}")
    with PLIST.open("rb") as f:
        data = plistlib.load(f)
    required = [
        "API_KEY",
        "GOOGLE_APP_ID",
        "GCM_SENDER_ID",
        "PROJECT_ID",
        "STORAGE_BUCKET",
        "BUNDLE_ID",
        "CLIENT_ID",
    ]
    for key in required:
        if not data.get(key):
            raise SystemExit(f"GoogleService-Info.plist missing {key}")
    return {k: str(data[k]) for k in required}


def load_android() -> dict[str, str]:
    if not GSERVICES.is_file():
        raise SystemExit(f"Missing {GSERVICES}")
    raw = json.loads(GSERVICES.read_text())
    project_id = raw["project_info"]["project_id"]
    storage = raw["project_info"]["storage_bucket"]
    sender = raw["project_info"]["project_number"]
    clients = raw.get("client") or []
    if not clients:
        raise SystemExit("google-services.json has no client entries")
    client = clients[0]
    api_key = client["api_key"][0]["current_key"]
    app_id = client["client_info"]["mobilesdk_app_id"]
    return {
        "API_KEY": api_key,
        "GOOGLE_APP_ID": app_id,
        "GCM_SENDER_ID": sender,
        "PROJECT_ID": project_id,
        "STORAGE_BUCKET": storage,
    }


def main() -> None:
    ios = load_ios()
    android = load_android()
    contents = f"""// GENERATED FILE — do not commit.
// Run: python3 tool/generate_firebase_options.py
// Source: GoogleService-Info.plist / google-services.json

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {{
  static FirebaseOptions get currentPlatform {{
    if (kIsWeb) {{
      throw UnsupportedError('Firebase web is not configured for EasyClip.');
    }}
    switch (defaultTargetPlatform) {{
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }}
  }}

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: '{ios["API_KEY"]}',
    appId: '{ios["GOOGLE_APP_ID"]}',
    messagingSenderId: '{ios["GCM_SENDER_ID"]}',
    projectId: '{ios["PROJECT_ID"]}',
    storageBucket: '{ios["STORAGE_BUCKET"]}',
    iosBundleId: '{ios["BUNDLE_ID"]}',
    iosClientId: '{ios["CLIENT_ID"]}',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: '{android["API_KEY"]}',
    appId: '{android["GOOGLE_APP_ID"]}',
    messagingSenderId: '{android["GCM_SENDER_ID"]}',
    projectId: '{android["PROJECT_ID"]}',
    storageBucket: '{android["STORAGE_BUCKET"]}',
  );
}}
"""
    OUT.write_text(contents)
    print(f"Wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
