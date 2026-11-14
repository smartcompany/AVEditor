package com.smartcompany.aveditor

import com.smartcompany.aveditor.nativevideo.NativeVideoEnginePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  override fun onCreate(savedInstanceState: android.os.Bundle?) {
    NativeVideoEnginePlugin.silenceCodecBufferPool()
    super.onCreate(savedInstanceState)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    NativeVideoEnginePlugin.registerWith(flutterEngine)
    MediaShareChannel.register(flutterEngine, this)
  }
}
