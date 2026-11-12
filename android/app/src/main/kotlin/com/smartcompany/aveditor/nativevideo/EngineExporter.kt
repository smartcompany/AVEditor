package com.smartcompany.aveditor.nativevideo

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Headless export through libaveditor_engine + GLES + MediaCodec muxer.
 */
internal object EngineExporter {
  private val cancelFlag = AtomicBoolean(false)
  @Volatile private var activeHandle: Long = 0L
  @Volatile private var activeNative: EngineNative? = null

  fun cancel() {
    cancelFlag.set(true)
    activeNative?.let { n ->
      val h = activeHandle
      if (h != 0L) n.nativeCancelExport(h)
    }
  }

  fun export(
    context: Context,
    args: Map<*, *>,
    onProgress: (Double) -> Unit,
    onComplete: (Result<String>) -> Unit,
  ) {
    cancelFlag.set(false)
    Thread({
      var handle = 0L
      var compositor: EngineCompositor? = null
      var recorder: EngineExportRecorder? = null
      val glThread = HandlerThread("aveditor-export-gl").also { it.start() }
      val glHandler = Handler(glThread.looper)
      val progressRef = AtomicReference(onProgress)
      var exportPlan: EnginePlanBuilder.EngineTimeline? = null
      val bridge = object : EngineNative() {
        override fun onEngineFrame(positionMs: Long, mask: Int, t: Float, effect: String?) {
          if (cancelFlag.get()) return
          val latch = CountDownLatch(1)
          glHandler.post {
            try {
              compositor?.draw(
                mask,
                exportPlan?.blendDrawAt(positionMs, mask),
                presentationNs = positionMs * 1_000_000L,
              )
              recorder?.drain(end = false)
            } finally {
              latch.countDown()
            }
          }
          latch.await()
        }

        override fun onEngineExportProgress(progress: Double) {
          progressRef.get().invoke(progress.coerceIn(0.0, 1.0))
        }
      }
      activeNative = bridge
      try {
        val sourcePath = args["sourcePath"] as? String
          ?: throw IllegalArgumentException("Missing sourcePath")
        val outputPath = args["outputPath"] as? String
          ?: throw IllegalArgumentException("Missing outputPath")
        File(outputPath).delete()
        val segments = args["segments"] as? List<*> ?: emptyList<Any>()
        val width = (args["width"] as? Number)?.toInt() ?: 1080
        val height = (args["height"] as? Number)?.toInt() ?: 1920
        val plan = EnginePlanBuilder.build(sourcePath, segments)
        exportPlan = plan
        val overlays = args["overlays"] as? List<*> ?: emptyList<Any>()
        val music = args["music"] as? List<*> ?: emptyList<Any>()
        if (overlays.isNotEmpty() || music.isNotEmpty()) {
          Log.i(
            "NativeVideoEngine",
            "engine export overlays=${overlays.size} music=${music.size} " +
              "(composited in a later pass; video+transitions only for now)",
          )
        }

        handle = bridge.nativeCreate()
        activeHandle = handle
        recorder = EngineExportRecorder(width, height, outputPath).also { it.start() }

        val ready = CountDownLatch(1)
        var bootErr: Exception? = null
        glHandler.post {
          try {
            val comp = EngineCompositor()
            comp.init(recorder!!.inputSurface, width, height)
            compositor = comp
            bridge.nativeSetDecoderSurface(handle, 0, comp.surfaceA)
            bridge.nativeSetDecoderSurface(handle, 1, comp.surfaceB)
            bridge.nativeSetPlan(handle, plan.json)
          } catch (e: Exception) {
            bootErr = e
          } finally {
            ready.countDown()
          }
        }
        ready.await()
        bootErr?.let { throw it }

        val rc = bridge.nativeExport(handle, outputPath, width, height)
        recorder?.finish()
        recorder = null

        when {
          cancelFlag.get() || rc == -2 -> {
            File(outputPath).delete()
            onComplete(Result.failure(IllegalStateException("export_cancelled")))
          }
          rc != 0 -> onComplete(Result.failure(IllegalStateException("export_failed_$rc")))
          else -> {
            onProgress(1.0)
            onComplete(Result.success(outputPath))
          }
        }
      } catch (e: Exception) {
        Log.e("NativeVideoEngine", "EngineExporter failed", e)
        try {
          recorder?.finish()
        } catch (_: Exception) {
        }
        onComplete(Result.failure(e))
      } finally {
        if (handle != 0L) {
          try {
            bridge.nativeRelease(handle)
          } catch (_: Exception) {
          }
        }
        activeHandle = 0L
        activeNative = null
        val done = CountDownLatch(1)
        glHandler.post {
          try {
            compositor?.release()
          } finally {
            done.countDown()
          }
        }
        done.await()
        glThread.quitSafely()
        cancelFlag.set(false)
        // Keep context referenced for symmetry with callers.
        @Suppress("UNUSED_EXPRESSION")
        context
      }
    }, "aveditor-export").start()
  }
}
