package com.smart.aveditor

import com.smart.aveditor.nativevideo.NativeVideoEnginePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    NativeVideoEnginePlugin.registerWith(flutterEngine)
  }
}
