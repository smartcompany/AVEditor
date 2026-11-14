package com.smartcompany.aveditor

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Sends an exported video straight to Instagram, TikTok or Facebook. Each
/// app then opens its own post/chat picker with the video already attached.
object MediaShareChannel {
  private const val CHANNEL = "aveditor/media_share"
  /// Only these apps may be targeted from Dart.
  private val ALLOWED = setOf(
    "com.instagram.android",
    "com.zhiliaoapp.musically",
    "com.ss.android.ugc.trill",
    "com.facebook.katana",
  )

  fun register(engine: FlutterEngine, activity: Activity) {
    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "shareVideoToApp" -> {
          val path = call.argument<String>("path")
          val pkg = call.argument<String>("package")
          if (path == null || pkg == null || pkg !in ALLOWED) {
            result.error("bad_args", "path/package", null)
          } else {
            result.success(shareToApp(activity, File(path), pkg))
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun shareToApp(activity: Activity, file: File, pkg: String): Boolean {
    if (!file.exists()) return false
    val uri = FileProvider.getUriForFile(
      activity,
      "${activity.packageName}.media_share",
      file,
    )
    activity.grantUriPermission(
      pkg,
      uri,
      Intent.FLAG_GRANT_READ_URI_PERMISSION,
    )
    val intent = Intent(Intent.ACTION_SEND).apply {
      type = "video/mp4"
      putExtra(Intent.EXTRA_STREAM, uri)
      clipData = ClipData.newRawUri("", uri)
      setPackage(pkg)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return try {
      activity.startActivity(intent)
      true
    } catch (_: ActivityNotFoundException) {
      false
    }
  }
}
