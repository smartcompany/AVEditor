package com.smartcompany.aveditor.nativevideo

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Android Native Video Engine bridge.
 * Timeline preview + album export use libaveditor_engine (own clock / MediaCodec / GLES).
 */
class NativeVideoEnginePlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler {

  private lateinit var channel: MethodChannel
  private lateinit var events: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var textureRegistry: TextureRegistry? = null
  private var appContext: Context? = null
  private var timeline: TimelineSession? = null

  companion object {
    const val CHANNEL = "com.smartcompany.aveditor/native_video_engine"
    const val EVENTS = "com.smartcompany.aveditor/native_video_engine/events"

    fun registerWith(engine: FlutterEngine) {
      engine.plugins.add(NativeVideoEnginePlugin())
    }

    fun silenceCodecBufferPool() {
      val tags = arrayOf(
        "BufferPoolAccessor2.0",
        "BufferPoolAccessor",
        "CCodecBuffers",
        "CCodecConfig",
        "Codec2-Output",
      )
      for (tag in tags) {
        val key = "log.tag.$tag"
        try {
          val clazz = Class.forName("android.os.SystemProperties")
          val set = clazz.getMethod("set", String::class.java, String::class.java)
          set.invoke(null, key, "S")
        } catch (_: Exception) {
        }
        try {
          Runtime.getRuntime().exec(arrayOf("setprop", key, "S")).waitFor()
        } catch (_: Exception) {
        }
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    silenceCodecBufferPool()
    appContext = binding.applicationContext
    textureRegistry = binding.textureRegistry
    channel = MethodChannel(binding.binaryMessenger, CHANNEL)
    channel.setMethodCallHandler(this)
    events = EventChannel(binding.binaryMessenger, EVENTS)
    events.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    events.setStreamHandler(null)
    timeline?.release()
    timeline = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    DebugAgentLog.eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
    DebugAgentLog.eventSink = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "prepareTimeline" -> {
        val args = call.arguments as? Map<*, *>
        val registry = textureRegistry
        val context = appContext
        val sourcePath = args?.get("sourcePath") as? String
        val segments = args?.get("segments") as? List<*>
        if (args == null || registry == null || context == null ||
          sourcePath == null || segments.isNullOrEmpty()
        ) {
          result.error("bad_args", "prepareTimeline", null)
          return
        }
        val current = timeline
        if (current != null) {
          try {
            current.update(sourcePath, segments)
            result.success(
              mapOf(
                "textureId" to current.textureId,
                "durationMs" to current.durationMs,
                "width" to current.width,
                "height" to current.height,
              ),
            )
          } catch (e: Exception) {
            Log.e("NativeVideoEngine", "updateTimeline failed", e)
            result.error("prepare_failed", e.message, null)
          }
          return
        }
        try {
          val enginePlan = EnginePlanBuilder.build(sourcePath, segments)
          val created = registry.createSurfaceTexture()
          try {
            val playing = TimelineEngineSession(
              appContext = context,
              surfaceTextureEntry = created,
              plan = enginePlan,
              onEvent = { event ->
                Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
              },
            )
            timeline = playing
            playing.start()
          } catch (e: Exception) {
            if (timeline == null) created.release()
            throw e
          }
          result.success(
            mapOf(
              "textureId" to created.id(),
              "durationMs" to enginePlan.durationMs,
              "width" to enginePlan.width,
              "height" to enginePlan.height,
            ),
          )
        } catch (e: Exception) {
          Log.e("NativeVideoEngine", "prepareTimeline failed", e)
          timeline?.release()
          timeline = null
          result.error("prepare_failed", e.message, null)
        }
      }

      "play" -> {
        val playing = timeline
        if (playing == null) {
          Log.e("NativeVideoEngine", "play failed timeline=null")
          result.error("play_failed", "timeline is null", null)
          return
        }
        try {
          playing.play { failure ->
            if (failure != null) {
              Log.e("NativeVideoEngine", "play failed $failure")
              result.error("play_failed", failure, null)
            } else {
              result.success(playing.playbackSnapshot())
            }
          }
        } catch (e: Exception) {
          Log.e("NativeVideoEngine", "play threw", e)
          result.error("play_failed", e.message, null)
        }
      }
      "pause" -> {
        timeline?.pause()
        result.success(null)
      }
      "seek" -> {
        val ms = ((call.arguments as? Map<*, *>)?.get("positionMs") as? Number)?.toLong() ?: 0L
        timeline?.seekToMs(ms)
        result.success(null)
      }
      "preroll" -> {
        val ms = ((call.arguments as? Map<*, *>)?.get("positionMs") as? Number)?.toLong() ?: 0L
        val playing = timeline
        if (playing == null) {
          result.success(false)
          return
        }
        playing.prerollToMs(ms) { ready -> result.success(ready) }
      }
      "dispose" -> {
        timeline?.release()
        timeline = null
        result.success(null)
      }

      "probe" -> {
        val path = (call.arguments as? Map<*, *>)?.get("path") as? String
        if (path == null) {
          result.error("bad_args", "probe", null)
          return
        }
        try {
          result.success(NativeVideoEngineMedia.probe(path))
        } catch (e: Exception) {
          result.error("probe_failed", e.message, null)
        }
      }

      "decodeWaveform" -> {
        val args = call.arguments as? Map<*, *>
        val path = args?.get("path") as? String
        val peakCount = (args?.get("peakCount") as? Number)?.toInt() ?: 240
        if (path == null) {
          result.error("bad_args", "decodeWaveform", null)
          return
        }
        Thread {
          try {
            val payload = NativeVideoEngineMedia.decodeWaveform(path, peakCount)
            Handler(Looper.getMainLooper()).post { result.success(payload) }
          } catch (e: Exception) {
            Handler(Looper.getMainLooper()).post {
              result.error("waveform_failed", e.message, null)
            }
          }
        }.start()
      }

      "cancelExport" -> {
        EngineExporter.cancel()
        NativeVideoEngineMedia.cancelExport()
        result.success(null)
      }

      "export" -> {
        val args = call.arguments as? Map<*, *>
        val context = appContext
        if (args == null || context == null) {
          result.error("bad_args", "export", null)
          return
        }
        EngineExporter.export(
          context = context,
          args = args,
          onProgress = { progress ->
            Handler(Looper.getMainLooper()).post {
              eventSink?.success(
                mapOf(
                  "type" to "exportProgress",
                  "progress" to progress,
                ),
              )
            }
          },
          onComplete = { exportResult ->
            Handler(Looper.getMainLooper()).post {
              exportResult.fold(
                onSuccess = { path -> result.success(mapOf("outputPath" to path)) },
                onFailure = { e ->
                  Log.e("NativeVideoEngine", "export failed", e)
                  result.error("export_failed", e.message ?: e.toString(), e.toString())
                },
              )
            }
          },
        )
      }

      else -> result.notImplemented()
    }
  }
}
