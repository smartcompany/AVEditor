package com.smart.aveditor.nativevideo

import android.content.Context
import android.media.MediaPlayer
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android timeline preview driven by libaveditor_engine (own clock + MediaCodec)
 * and [EngineCompositor] (GLES). Solos use one decoder slot; blends use two.
 */
internal class TimelineEngineSession(
  @Suppress("unused") private val appContext: Context,
  private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
  private var plan: EnginePlanBuilder.EngineTimeline,
  private val onEvent: (Map<String, Any>) -> Unit,
) : EngineNative(), TimelineSession {
  private val main = Handler(Looper.getMainLooper())
  private val glThread = HandlerThread("aveditor-engine-gl").also { it.start() }
  private val glHandler = Handler(glThread.looper)
  private val pumpThread = HandlerThread("aveditor-engine-pump").also { it.start() }
  private val pumpHandler = Handler(pumpThread.looper)

  private var handle = 0L
  private var compositor: EngineCompositor? = null
  private var outputSurface: Surface? = null
  private var audioPlayer: MediaPlayer? = null
  private val released = AtomicBoolean(false)
  private var lastDrawnMs = -1L

  override val textureId: Long get() = surfaceTextureEntry.id()
  override val durationMs: Int get() = plan.durationMs
  override val width: Int get() = plan.width
  override val height: Int get() = plan.height

  override fun onEngineFrame(positionMs: Long, mask: Int, t: Float, effect: String?) {
    val draw = plan.blendDrawAt(positionMs, mask)
    glHandler.post {
      if (released.get()) return@post
      compositor?.draw(mask, draw)
      lastDrawnMs = positionMs
      main.post {
        onEvent(mapOf("type" to "position", "positionMs" to positionMs.toInt()))
      }
    }
  }

  override fun start() {
    handle = nativeCreate()
    val latch = CountDownLatch(1)
    var error: Exception? = null
    glHandler.post {
      try {
        val texture = surfaceTextureEntry.surfaceTexture()
        texture.setDefaultBufferSize(plan.width, plan.height)
        val out = Surface(texture)
        outputSurface = out
        val comp = EngineCompositor()
        comp.init(out, plan.width, plan.height)
        compositor = comp
        nativeSetOutputSurface(handle, out)
        nativeSetDecoderSurface(handle, 0, comp.surfaceA)
        nativeSetDecoderSurface(handle, 1, comp.surfaceB)
        nativeSetPlan(handle, plan.json)
      } catch (e: Exception) {
        error = e
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    error?.let { throw it }
    prepareAudio()
    schedulePump()
    Log.i("NativeVideoEngine", "timeline player=aveditor_engine")
  }

  private fun schedulePump() {
    pumpHandler.post(object : Runnable {
      override fun run() {
        if (released.get() || handle == 0L) return
        try {
          nativePump(handle)
          if (nativeIsPlaying(handle)) {
            val pos = nativePositionMs(handle)
            main.post {
              onEvent(mapOf("type" to "position", "positionMs" to pos.toInt()))
            }
            syncAudio(pos)
            if (pos >= plan.durationMs) {
              nativePause(handle)
              main.post {
                onEvent(mapOf("type" to "playing", "playing" to false))
                onEvent(mapOf("type" to "completed"))
              }
              pauseAudio()
            }
          }
        } catch (e: Exception) {
          Log.e("NativeVideoEngine", "pump failed", e)
        }
        if (!released.get()) pumpHandler.postDelayed(this, 16L)
      }
    })
  }

  private fun prepareAudio() {
    if (!plan.hasAudio) return
    try {
      audioPlayer?.release()
      audioPlayer = MediaPlayer().apply {
        setDataSource(plan.sourcePath)
        setVolume(1f, 1f)
        prepare()
      }
    } catch (e: Exception) {
      Log.e("NativeVideoEngine", "audio prepare failed", e)
      audioPlayer = null
    }
  }

  private fun syncAudio(posMs: Long) {
    val player = audioPlayer ?: return
    try {
      if (kotlin.math.abs(player.currentPosition - posMs.toInt()) > 120) {
        player.seekTo(posMs.toInt().coerceAtLeast(0))
      }
    } catch (_: Exception) {
    }
  }

  private fun pauseAudio() {
    try {
      audioPlayer?.pause()
    } catch (_: Exception) {
    }
  }

  private fun playAudio() {
    val player = audioPlayer ?: return
    try {
      player.seekTo(nativePositionMs(handle).toInt().coerceAtLeast(0))
      player.start()
    } catch (e: Exception) {
      Log.e("NativeVideoEngine", "audio play failed", e)
    }
  }

  override fun update(sourcePath: String, segments: List<*>) {
    // set_plan resets the engine clock to 0; keep the playhead where it was.
    val keepMs = nativePositionMs(handle)
    plan = EnginePlanBuilder.build(sourcePath, segments)
    nativeSetPlan(handle, plan.json)
    prepareAudio()
    nativeSeek(handle, keepMs.coerceIn(0L, plan.durationMs.toLong()))
    pumpHandler.post {
      repeat(8) { nativePump(handle) }
    }
  }

  override fun play(done: (String?) -> Unit) {
    if (released.get() || handle == 0L) {
      done("released")
      return
    }
    nativePlay(handle)
    playAudio()
    onEvent(mapOf("type" to "playing", "playing" to true))
    done(null)
  }

  override fun playbackSnapshot(): Map<String, Any> {
    return mapOf(
      "state" to "ready",
      "pos" to nativePositionMs(handle),
      "playWhenReady" to nativeIsPlaying(handle),
      "isPlaying" to nativeIsPlaying(handle),
      "error" to "",
    )
  }

  override fun pause() {
    if (handle == 0L) return
    nativePause(handle)
    pauseAudio()
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  override fun seekToMs(ms: Long) {
    if (handle == 0L) return
    val land = ms.coerceIn(0L, plan.durationMs.toLong())
    nativePause(handle)
    pauseAudio()
    nativeSeek(handle, land)
    pumpHandler.post {
      repeat(8) { nativePump(handle) }
    }
    onEvent(mapOf("type" to "position", "positionMs" to land.toInt()))
  }

  override fun prerollToMs(ms: Long, done: (Boolean) -> Unit) {
    if (handle == 0L) {
      done(false)
      return
    }
    val land = ms.coerceIn(0L, plan.durationMs.toLong())
    nativePause(handle)
    nativeSeek(handle, land)
    pumpHandler.post {
      var ok = false
      repeat(24) {
        if (nativePump(handle) != 0) ok = true
      }
      glHandler.postDelayed({
        main.post {
          onEvent(mapOf("type" to "position", "positionMs" to land.toInt()))
          done(ok || lastDrawnMs >= 0L)
        }
      }, 40L)
    }
  }

  override fun release() {
    if (!released.compareAndSet(false, true)) return
    if (handle != 0L) nativeCancelExport(handle)
    pauseAudio()
    try {
      audioPlayer?.release()
    } catch (_: Exception) {
    }
    audioPlayer = null
    pumpHandler.removeCallbacksAndMessages(null)
    glHandler.removeCallbacksAndMessages(null)
    val h = handle
    handle = 0L
    if (h != 0L) nativeRelease(h)
    val latch = CountDownLatch(1)
    glHandler.post {
      try {
        compositor?.release()
        compositor = null
        outputSurface?.release()
        outputSurface = null
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    pumpThread.quitSafely()
    glThread.quitSafely()
    surfaceTextureEntry.release()
  }
}
