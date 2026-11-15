package com.smartcompany.aveditor

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Sends an exported video straight to Instagram, TikTok, Facebook or YouTube.
object MediaShareChannel {
  private const val CHANNEL = "aveditor/media_share"
  private const val YOUTUBE_PACKAGE = "com.google.android.youtube"
  private const val YOUTUBE_UPLOAD_ACTION =
    "com.google.android.youtube.intent.action.UPLOAD"

  /// Only these apps may be targeted from Dart.
  private val ALLOWED = setOf(
    "com.instagram.android",
    "com.zhiliaoapp.musically",
    "com.ss.android.ugc.trill",
    "com.facebook.katana",
    YOUTUBE_PACKAGE,
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
        "shareToYouTube" -> {
          val path = call.argument<String>("path")
          if (path == null) {
            result.error("bad_args", "path", null)
          } else {
            shareToYouTube(activity, File(path)) { ok -> result.success(ok) }
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  /**
   * Opens YouTube's upload flow with the video attached.
   * Prefers the official UPLOAD intent (needs a MediaStore content:// URI),
   * then falls back to ACTION_SEND into the YouTube package.
   */
  private fun shareToYouTube(
    activity: Activity,
    file: File,
    done: (Boolean) -> Unit,
  ) {
    if (!file.exists()) {
      done(false)
      return
    }
    MediaScannerConnection.scanFile(
      activity,
      arrayOf(file.absolutePath),
      arrayOf("video/mp4"),
    ) { _, uri ->
      activity.runOnUiThread {
        if (uri != null && tryYouTubeUpload(activity, uri)) {
          done(true)
          return@runOnUiThread
        }
        done(shareToApp(activity, file, YOUTUBE_PACKAGE))
      }
    }
  }

  private fun tryYouTubeUpload(activity: Activity, mediaUri: Uri): Boolean {
    if (!mediaUri.toString().startsWith("content://media/")) return false
    val intent = Intent(YOUTUBE_UPLOAD_ACTION).apply {
      setPackage(YOUTUBE_PACKAGE)
      setDataAndType(mediaUri, "video/*")
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return try {
      activity.startActivity(intent)
      true
    } catch (_: ActivityNotFoundException) {
      false
    } catch (_: Exception) {
      false
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
