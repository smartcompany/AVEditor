package com.smart.aveditor.nativevideo

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Android Native Video Engine
 *   ├── Media3-timed decode
 *   └── GPU Renderer (OpenGL ES slide/push + opacity crossfade)
 */
@UnstableApi
class NativeVideoEnginePlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler {

  private lateinit var channel: MethodChannel
  private lateinit var events: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var textureRegistry: TextureRegistry? = null
  private var appContext: Context? = null
  private var session: NativePlaybackSession? = null

  companion object {
    const val CHANNEL = "com.smart.aveditor/native_video_engine"
    const val EVENTS = "com.smart.aveditor/native_video_engine/events"

    fun registerWith(engine: FlutterEngine) {
      engine.plugins.add(NativeVideoEnginePlugin())
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
    session?.release()
    session = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "prepareTimeline" -> {
        val args = call.arguments as? Map<*, *>
        val registry = textureRegistry
        if (args == null || registry == null) {
          result.error("bad_args", "prepareTimeline", null)
          return
        }
        val sourcePath = args["sourcePath"] as? String
        val durationMs = (args["durationMs"] as? Number)?.toLong()
        @Suppress("UNCHECKED_CAST")
        val segments = args["segments"] as? List<Map<String, Any?>>
        if (sourcePath == null || durationMs == null || segments == null) {
          result.error("bad_args", "prepareTimeline", null)
          return
        }
        val width = (args["width"] as? Number)?.toInt() ?: 720
        val height = (args["height"] as? Number)?.toInt() ?: 1280
        session?.release()
        try {
          val entry = registry.createSurfaceTexture()
          val packed = TimelinePacker.pack(segments)
          val s = TimelineEngineSession(
            surfaceTextureEntry = entry,
            sourcePath = sourcePath,
            ranges = packed,
            durationUs = durationMs * 1000L,
            width = width,
            height = height,
            onEvent = { event ->
              Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
            },
          )
          s.start()
          session = s
          result.success(
            mapOf(
              "textureId" to entry.id(),
              "durationMs" to durationMs.toInt(),
            ),
          )
        } catch (e: Exception) {
          result.error("prepare_failed", e.message, null)
        }
      }

      "prepareTransition" -> {
        val args = call.arguments as? Map<*, *>
        val registry = textureRegistry
        if (args == null || registry == null) {
          result.error("bad_args", "prepareTransition", null)
          return
        }
        val sourcePath = args["sourcePath"] as? String
        val effect = args["effect"] as? String
        val durationMs = (args["durationMs"] as? Number)?.toLong()
        val outStartMs = (args["outgoingStartMs"] as? Number)?.toLong()
        val outEndMs = (args["outgoingEndMs"] as? Number)?.toLong()
        val inStartMs = (args["incomingStartMs"] as? Number)?.toLong()
        val inEndMs = (args["incomingEndMs"] as? Number)?.toLong()
        if (sourcePath == null || effect == null || durationMs == null ||
          outStartMs == null || outEndMs == null || inStartMs == null || inEndMs == null
        ) {
          result.error("bad_args", "prepareTransition", null)
          return
        }
        session?.release()
        try {
          val entry = registry.createSurfaceTexture()
          val s = TransitionEngineSession(
            surfaceTextureEntry = entry,
            sourcePath = sourcePath,
            outgoingStartUs = outStartMs * 1000L,
            outgoingEndUs = outEndMs * 1000L,
            incomingStartUs = inStartMs * 1000L,
            incomingEndUs = inEndMs * 1000L,
            durationUs = durationMs * 1000L,
            effect = effect,
            onEvent = { event ->
              Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
            },
          )
          s.start()
          session = s
          result.success(
            mapOf(
              "textureId" to entry.id(),
              "durationMs" to durationMs.toInt(),
            ),
          )
        } catch (e: Exception) {
          result.error("prepare_failed", e.message, null)
        }
      }

      "play" -> {
        session?.play()
        result.success(null)
      }
      "pause" -> {
        session?.pause()
        result.success(null)
      }
      "seek" -> {
        val ms = ((call.arguments as? Map<*, *>)?.get("positionMs") as? Number)?.toLong() ?: 0L
        session?.seekToMs(ms)
        result.success(null)
      }
      "preroll" -> {
        val ms = ((call.arguments as? Map<*, *>)?.get("positionMs") as? Number)?.toLong() ?: 0L
        val ready = session?.prerollToMs(ms) ?: false
        result.success(ready)
      }
      "dispose" -> {
        session?.release()
        session = null
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

      "export" -> {
        val args = call.arguments as? Map<*, *>
        val context = appContext
        if (args == null || context == null) {
          result.error("bad_args", "export", null)
          return
        }
        NativeVideoEngineMedia.export(
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
                onFailure = { e -> result.error("export_failed", e.message, null) },
              )
            }
          },
        )
      }

      else -> result.notImplemented()
    }
  }
}

private interface NativePlaybackSession {
  fun play()
  fun pause()
  fun seekToMs(ms: Long)
  fun prerollToMs(ms: Long): Boolean
  fun release()
}

private data class PackedRange(
  val compositionStartUs: Long,
  val compositionEndUs: Long,
  val sourceStartUs: Long,
  val sourceEndUs: Long,
  val transitionStartUs: Long?,
  val transitionEndUs: Long?,
  val transitionEffect: String?,
  val incomingSourceStartUs: Long?,
  val volume: Float,
)

private object TimelinePacker {
  fun pack(segments: List<Map<String, Any?>>): List<PackedRange> {
    val out = ArrayList<PackedRange>()
    var cursorUs = 0L
    for (i in segments.indices) {
      val seg = segments[i]
      val startMs = (seg["startMs"] as? Number)?.toLong() ?: 0L
      val endMs = (seg["endMs"] as? Number)?.toLong() ?: 0L
      val tdMs = (seg["transitionDurationMs"] as? Number)?.toLong() ?: 0L
      val effect = seg["transitionEffect"] as? String
      val volume = (seg["volume"] as? Number)?.toFloat()?.coerceIn(0f, 2f) ?: 1f
      val durUs = max(0L, (endMs - startMs) * 1000L)
      val tdUs = max(0L, tdMs * 1000L)
      val compStart = cursorUs
      val compEnd = cursorUs + durUs
      val nextStartMs = if (i < segments.lastIndex) {
        (segments[i + 1]["startMs"] as? Number)?.toLong() ?: 0L
      } else {
        null
      }
      if (tdU > 0 && nextStartMs != null) {
        out.add(
          PackedRange(
            compositionStartUs = compStart,
            compositionEndUs = compEnd,
            sourceStartUs = startMs * 1000L,
            sourceEndUs = endMs * 1000L,
            transitionStartUs = compEnd - tdU,
            transitionEndUs = compEnd,
            transitionEffect = effect?.lowercase() ?: "dissolve",
            incomingSourceStartUs = nextStartMs * 1000L,
            volume = volume,
          ),
        )
      } else {
        out.add(
          PackedRange(
            compositionStartUs = compStart,
            compositionEndUs = compEnd,
            sourceStartUs = startMs * 1000L,
            sourceEndUs = endMs * 1000L,
            transitionStartUs = null,
            transitionEndUs = null,
            transitionEffect = null,
            incomingSourceStartUs = null,
            volume = volume,
          ),
        )
      }
      cursorUs = compEnd
    }
    return out
  }
}

/** Continuous timeline playback with dual-decoder GPU blend at cuts. */
@UnstableApi
private class TimelineEngineSession(
  private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
  private val sourcePath: String,
  private val ranges: List<PackedRange>,
  private val durationUs: Long,
  private val width: Int,
  private val height: Int,
  private val onEvent: (Map<String, Any>) -> Unit,
) : NativePlaybackSession {
  private val glThread = HandlerThread("native-timeline-gl").also { it.start() }
  private val glHandler = Handler(glThread.looper)
  private val playing = AtomicBoolean(false)
  private var released = false

  private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
  private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var program = 0
  private var outTexId = 0
  private var inTexId = 0
  private var outSurfaceTexture: SurfaceTexture? = null
  private var inSurfaceTexture: SurfaceTexture? = null
  private var outSurface: Surface? = null
  private var inSurface: Surface? = null
  private var outDecoder: Media3ClipDecoder? = null
  private var inDecoder: Media3ClipDecoder? = null
  private var positionUs = 0L
  private var startWallNs = 0L
  private var startPosUs = 0L
  private var lastOutSourceUs = -1L
  private var lastInSourceUs = -1L
  private var lastActiveCompositionStartUs = -1L
  private var audio: CompositionAudioPlayer? = null

  fun start() {
    val latch = CountDownLatch(1)
    var error: Exception? = null
    glHandler.post {
      try {
        initGl()
        outDecoder = Media3ClipDecoder(sourcePath, outSurface!!)
        inDecoder = Media3ClipDecoder(sourcePath, inSurface!!)
        outDecoder!!.start()
        inDecoder!!.start()
        outDecoder!!.seekTo(0L)
        renderAt(0L, forceSeek = true)
      } catch (e: Exception) {
        error = e
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    error?.let { throw it }
    audio = CompositionAudioPlayer(sourcePath, ranges, durationUs).also {
      try {
        it.prepare()
        it.seekTo(0L)
      } catch (_: Exception) {
        audio = null
      }
    }
  }

  override fun play() {
    playing.set(true)
    startWallNs = System.nanoTime()
    startPosUs = positionUs
    onEvent(mapOf("type" to "playing", "playing" to true))
    // Warm continuous stream from current source time.
    glHandler.post {
      val active = ranges.firstOrNull {
        positionUs >= it.compositionStartUs && positionUs < it.compositionEndUs
      } ?: ranges.lastOrNull()
      if (active != null) {
        val localUs = positionUs - active.compositionStartUs
        outDecoder?.seekTo(active.sourceStartUs + localUs)
        lastOutSourceUs = active.sourceStartUs + localUs
      }
    }
    audio?.seekTo(positionUs)
    audio?.play()
    scheduleTick()
  }

  override fun pause() {
    playing.set(false)
    audio?.pause()
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  override fun seekToMs(ms: Long) {
    val us = (ms * 1000L).coerceIn(0L, durationUs)
    positionUs = us
    startWallNs = System.nanoTime()
    startPosUs = us
    if (playing.get()) {
      audio?.seekTo(us)
    }
    glHandler.post {
      renderAt(us, forceSeek = true)
      onEvent(mapOf("type" to "position", "positionMs" to (us / 1000L).toInt()))
    }
  }

  override fun prerollToMs(ms: Long): Boolean {
    val us = (ms * 1000L).coerceIn(0L, durationUs)
    val latch = CountDownLatch(1)
    var ready = false
    glHandler.post {
      try {
        positionUs = us
        startWallNs = System.nanoTime()
        startPosUs = us
        lastActiveCompositionStartUs = -1L
        lastOutSourceUs = -1L
        lastInSourceUs = -1L
        renderAt(us, forceSeek = true)
        ready = true
        onEvent(mapOf("type" to "position", "positionMs" to (us / 1000L).toInt()))
      } catch (_: Exception) {
        ready = false
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    // Audio is sought on play() — keep scrub video-only and responsive.
    return ready
  }

  override fun release() {
    if (released) return
    released = true
    playing.set(false)
    audio?.release()
    audio = null
    val latch = CountDownLatch(1)
    glHandler.post {
      try {
        outDecoder?.release()
        inDecoder?.release()
        outSurface?.release()
        inSurface?.release()
        outSurfaceTexture?.release()
        inSurfaceTexture?.release()
        if (program != 0) GLES20.glDeleteProgram(program)
        if (outTexId != 0) GLES20.glDeleteTextures(2, intArrayOf(outTexId, inTexId), 0)
        releaseEgl()
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    glThread.quitSafely()
    surfaceTextureEntry.release()
  }

  private fun scheduleTick() {
    if (!playing.get() || released) return
    glHandler.postDelayed({
      if (!playing.get() || released) return@postDelayed
      val elapsedUs = (System.nanoTime() - startWallNs) / 1000L
      positionUs = (startPosUs + elapsedUs).coerceAtMost(durationUs)
      renderAt(positionUs, forceSeek = false)
      onEvent(mapOf("type" to "position", "positionMs" to (positionUs / 1000L).toInt()))
      if (positionUs >= durationUs) {
        playing.set(false)
        audio?.pause()
        onEvent(mapOf("type" to "completed"))
        onEvent(mapOf("type" to "playing", "playing" to false))
      } else {
        scheduleTick()
      }
    }, 33L)
  }

  private fun renderAt(compositionUs: Long, forceSeek: Boolean) {
    val active = ranges.firstOrNull {
      compositionUs >= it.compositionStartUs && compositionUs < it.compositionEndUs
    } ?: ranges.lastOrNull() ?: return

    // Kept-range boundaries jump in source time — never advance across a cut.
    val rangeChanged = lastActiveCompositionStartUs != active.compositionStartUs
    lastActiveCompositionStartUs = active.compositionStartUs
    val hardSeek = forceSeek || rangeChanged

    val localUs = compositionUs - active.compositionStartUs
    val outSourceUs = active.sourceStartUs + localUs
    feedDecoder(isOut = true, sourceUs = outSourceUs, forceSeek = hardSeek)

    val inTransition = active.transitionStartUs != null &&
      active.transitionEndUs != null &&
      compositionUs >= active.transitionStartUs!! &&
      compositionUs < active.transitionEndUs!!

    if (inTransition && active.incomingSourceStartUs != null) {
      val tU = compositionUs - active.transitionStartUs!!
      val td = (active.transitionEndUs!! - active.transitionStartUs!!).coerceAtLeast(1L)
      val t = (tU.toFloat() / td.toFloat()).coerceIn(0f, 1f)
      val inSource = active.incomingSourceStartUs + tU
      feedDecoder(isOut = false, sourceUs = inSource, forceSeek = hardSeek || tU < 40_000L)
      drawBlend(active.transitionEffect ?: "dissolve", t)
    } else {
      drawPassthrough()
    }
  }

  private fun feedDecoder(isOut: Boolean, sourceUs: Long, forceSeek: Boolean) {
    val decoder = if (isOut) outDecoder else inDecoder
    val last = if (isOut) lastOutSourceUs else lastInSourceUs
    val d = decoder ?: return
    if (forceSeek || last < 0L || sourceUs + 80_000L < last || sourceUs > last + 500_000L) {
      d.seekTo(sourceUs)
    } else {
      d.advanceTo(sourceUs)
    }
    if (isOut) lastOutSourceUs = sourceUs else lastInSourceUs = sourceUs
  }

  private fun initGl() {
    eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    val version = IntArray(2)
    EGL14.eglInitialize(eglDisplay, version, 0, version, 1)
    val attribList = intArrayOf(
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val numConfigs = IntArray(1)
    EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
    eglContext = EGL14.eglCreateContext(
      eglDisplay,
      configs[0],
      EGL14.EGL_NO_CONTEXT,
      intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
      0,
    )
    val flutterSt = surfaceTextureEntry.surfaceTexture()
    flutterSt.setDefaultBufferSize(width, height)
    eglSurface = EGL14.eglCreateWindowSurface(
      eglDisplay,
      configs[0],
      flutterSt,
      intArrayOf(EGL14.EGL_NONE),
      0,
    )
    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

    outTexId = createOesTexture()
    inTexId = createOesTexture()
    outSurfaceTexture = SurfaceTexture(outTexId).also { it.setDefaultBufferSize(width, height) }
    inSurfaceTexture = SurfaceTexture(inTexId).also { it.setDefaultBufferSize(width, height) }
    outSurface = Surface(outSurfaceTexture)
    inSurface = Surface(inSurfaceTexture)
    program = buildProgram(VERTEX, FRAGMENT)
  }

  private fun releaseEgl() {
    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(
        eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
      )
      if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
      if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
      EGL14.eglTerminate(eglDisplay)
    }
    eglDisplay = EGL14.EGL_NO_DISPLAY
    eglContext = EGL14.EGL_NO_CONTEXT
    eglSurface = EGL14.EGL_NO_SURFACE
  }

  private fun drawPassthrough() {
    outSurfaceTexture?.updateTexImage()
    GLES20.glViewport(0, 0, width, height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glUseProgram(program)
    GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uOpacity"), 1f)
    drawLayer(outTexId, 0f, 0f, 1f)
    EGL14.eglSwapBuffers(eglDisplay, eglSurface)
  }

  private fun drawBlend(effect: String, t: Float) {
    outSurfaceTexture?.updateTexImage()
    inSurfaceTexture?.updateTexImage()
    GLES20.glViewport(0, 0, width, height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glEnable(GLES20.GL_BLEND)
    GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
    GLES20.glUseProgram(program)
    val slide = GpuSlideRenderer.isSlide(effect)
    if (slide) {
      val (outOff, inOff) = GpuSlideRenderer.offsets(effect, t)
      drawLayer(outTexId, outOff[0], outOff[1], 1f)
      drawLayer(inTexId, inOff[0], inOff[1], 1f)
    } else {
      drawLayer(outTexId, 0f, 0f, 1f - t)
      drawLayer(inTexId, 0f, 0f, t)
    }
    GLES20.glDisable(GLES20.GL_BLEND)
    EGL14.eglSwapBuffers(eglDisplay, eglSurface)
  }

  private fun drawLayer(texId: Int, offsetX: Float, offsetY: Float, opacity: Float) {
    val uTex = GLES20.glGetUniformLocation(program, "uTexture")
    val uOff = GLES20.glGetUniformLocation(program, "uOffset")
    val uOpacity = GLES20.glGetUniformLocation(program, "uOpacity")
    val aPos = GLES20.glGetAttribLocation(program, "aPosition")
    val aUv = GLES20.glGetAttribLocation(program, "aTexCoord")
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
    GLES20.glUniform1i(uTex, 0)
    GLES20.glUniform2f(uOff, offsetX, offsetY)
    GLES20.glUniform1f(uOpacity, opacity)
    val verts = floatArrayOf(-1f, -1f, 0f, 1f, 1f, -1f, 1f, 1f, -1f, 1f, 0f, 0f, 1f, 1f, 1f, 0f)
    val bb = ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
    bb.put(verts).position(0)
    GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, bb)
    GLES20.glEnableVertexAttribArray(aPos)
    val uv = bb.duplicate()
    uv.position(2)
    GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 16, uv)
    GLES20.glEnableVertexAttribArray(aUv)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
  }

  private fun createOesTexture(): Int {
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    return ids[0]
  }

  private fun buildProgram(vertex: String, fragment: String): Int {
    fun load(type: Int, src: String): Int {
      val s = GLES20.glCreateShader(type)
      GLES20.glShaderSource(s, src)
      GLES20.glCompileShader(s)
      return s
    }
    val prog = GLES20.glCreateProgram()
    GLES20.glAttachShader(prog, load(GLES20.GL_VERTEX_SHADER, vertex))
    GLES20.glAttachShader(prog, load(GLES20.GL_FRAGMENT_SHADER, fragment))
    GLES20.glLinkProgram(prog)
    return prog
  }

  companion object {
    private const val VERTEX = """
      attribute vec4 aPosition;
      attribute vec2 aTexCoord;
      uniform vec2 uOffset;
      varying vec2 vTexCoord;
      void main() {
        gl_Position = vec4(aPosition.xy + uOffset, 0.0, 1.0);
        vTexCoord = aTexCoord;
      }
    """
    private const val FRAGMENT = """
      #extension GL_OES_EGL_image_external : require
      precision mediump float;
      varying vec2 vTexCoord;
      uniform samplerExternalOES uTexture;
      uniform float uOpacity;
      void main() {
        vec4 c = texture2D(uTexture, vTexCoord);
        gl_FragColor = vec4(c.rgb, c.a * uOpacity);
      }
    """
  }
}

/** Legacy single-cut transition session. */
@UnstableApi
private class TransitionEngineSession(
  private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
  private val sourcePath: String,
  private val outgoingStartUs: Long,
  private val outgoingEndUs: Long,
  private val incomingStartUs: Long,
  private val incomingEndUs: Long,
  private val durationUs: Long,
  private val effect: String,
  private val onEvent: (Map<String, Any>) -> Unit,
) : NativePlaybackSession {
  private val glThread = HandlerThread("native-video-engine-gl").also { it.start() }
  private val glHandler = Handler(glThread.looper)
  private val playing = AtomicBoolean(false)
  private var released = false

  private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
  private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var program = 0
  private var outTexId = 0
  private var inTexId = 0
  private var outSurfaceTexture: SurfaceTexture? = null
  private var inSurfaceTexture: SurfaceTexture? = null
  private var outSurface: Surface? = null
  private var inSurface: Surface? = null
  private var outDecoder: Media3ClipDecoder? = null
  private var inDecoder: Media3ClipDecoder? = null
  private var positionUs = 0L
  private var startWallNs = 0L
  private var startPosUs = 0L
  private val width = 720
  private val height = 1280

  fun start() {
    val latch = CountDownLatch(1)
    var error: Exception? = null
    glHandler.post {
      try {
        initGl()
        outDecoder = Media3ClipDecoder(sourcePath, outSurface!!)
        inDecoder = Media3ClipDecoder(sourcePath, inSurface!!)
        outDecoder!!.start()
        inDecoder!!.start()
        outDecoder!!.seekTo(outgoingStartUs)
        inDecoder!!.seekTo(incomingStartUs)
        drawFrame(0f)
      } catch (e: Exception) {
        error = e
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    error?.let { throw it }
  }

  override fun play() {
    playing.set(true)
    startWallNs = System.nanoTime()
    startPosUs = positionUs
    onEvent(mapOf("type" to "playing", "playing" to true))
    scheduleTick()
  }

  override fun pause() {
    playing.set(false)
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  override fun seekToMs(ms: Long) {
    val us = (ms * 1000L).coerceIn(0L, durationUs)
    positionUs = us
    startWallNs = System.nanoTime()
    startPosUs = us
    glHandler.post {
      outDecoder?.seekTo(outgoingStartUs + us)
      inDecoder?.seekTo(incomingStartUs + us)
      val t = if (durationUs > 0) us.toFloat() / durationUs else 1f
      drawFrame(t.coerceIn(0f, 1f))
      onEvent(mapOf("type" to "position", "positionMs" to (us / 1000L).toInt()))
    }
  }

  override fun prerollToMs(ms: Long): Boolean {
    val us = (ms * 1000L).coerceIn(0L, durationUs)
    val latch = CountDownLatch(1)
    var ready = false
    glHandler.post {
      try {
        positionUs = us
        startWallNs = System.nanoTime()
        startPosUs = us
        outDecoder?.seekTo(outgoingStartUs + us)
        inDecoder?.seekTo(incomingStartUs + us)
        val t = if (durationUs > 0) us.toFloat() / durationUs else 1f
        drawFrame(t.coerceIn(0f, 1f))
        ready = true
        onEvent(mapOf("type" to "position", "positionMs" to (us / 1000L).toInt()))
      } catch (_: Exception) {
        ready = false
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    return ready
  }

  override fun release() {
    if (released) return
    released = true
    playing.set(false)
    val latch = CountDownLatch(1)
    glHandler.post {
      try {
        outDecoder?.release()
        inDecoder?.release()
        outSurface?.release()
        inSurface?.release()
        outSurfaceTexture?.release()
        inSurfaceTexture?.release()
        if (program != 0) GLES20.glDeleteProgram(program)
        if (outTexId != 0) GLES20.glDeleteTextures(2, intArrayOf(outTexId, inTexId), 0)
        releaseEgl()
      } finally {
        latch.countDown()
      }
    }
    latch.await()
    glThread.quitSafely()
    surfaceTextureEntry.release()
  }

  private fun scheduleTick() {
    if (!playing.get() || released) return
    glHandler.postDelayed({
      if (!playing.get() || released) return@postDelayed
      val elapsedUs = (System.nanoTime() - startWallNs) / 1000L
      positionUs = (startPosUs + elapsedUs).coerceAtMost(durationUs)
      val t = if (durationUs > 0) positionUs.toFloat() / durationUs else 1f
      outDecoder?.advanceTo(outgoingStartUs + positionUs)
      inDecoder?.advanceTo(incomingStartUs + positionUs)
      drawFrame(t.coerceIn(0f, 1f))
      onEvent(mapOf("type" to "position", "positionMs" to (positionUs / 1000L).toInt()))
      if (positionUs >= durationUs) {
        playing.set(false)
        onEvent(mapOf("type" to "completed"))
        onEvent(mapOf("type" to "playing", "playing" to false))
      } else {
        scheduleTick()
      }
    }, 16L)
  }

  private fun initGl() {
    eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    val version = IntArray(2)
    EGL14.eglInitialize(eglDisplay, version, 0, version, 1)
    val attribList = intArrayOf(
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val numConfigs = IntArray(1)
    EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
    eglContext = EGL14.eglCreateContext(
      eglDisplay,
      configs[0],
      EGL14.EGL_NO_CONTEXT,
      intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
      0,
    )
    val flutterSt = surfaceTextureEntry.surfaceTexture()
    flutterSt.setDefaultBufferSize(width, height)
    eglSurface = EGL14.eglCreateWindowSurface(
      eglDisplay,
      configs[0],
      flutterSt,
      intArrayOf(EGL14.EGL_NONE),
      0,
    )
    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

    outTexId = createOesTexture()
    inTexId = createOesTexture()
    outSurfaceTexture = SurfaceTexture(outTexId).also { it.setDefaultBufferSize(width, height) }
    inSurfaceTexture = SurfaceTexture(inTexId).also { it.setDefaultBufferSize(width, height) }
    outSurface = Surface(outSurfaceTexture)
    inSurface = Surface(inSurfaceTexture)
    program = buildProgram(VERTEX, FRAGMENT)
  }

  private fun releaseEgl() {
    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(
        eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
      )
      if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
      if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
      EGL14.eglTerminate(eglDisplay)
    }
    eglDisplay = EGL14.EGL_NO_DISPLAY
    eglContext = EGL14.EGL_NO_CONTEXT
    eglSurface = EGL14.EGL_NO_SURFACE
  }

  private fun drawFrame(t: Float) {
    outSurfaceTexture?.updateTexImage()
    inSurfaceTexture?.updateTexImage()
    GLES20.glViewport(0, 0, width, height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glUseProgram(program)
    val (outOff, inOff) = GpuSlideRenderer.offsets(effect, t)
    drawLayer(outTexId, outOff[0], outOff[1])
    drawLayer(inTexId, inOff[0], inOff[1])
    EGL14.eglSwapBuffers(eglDisplay, eglSurface)
  }

  private fun drawLayer(texId: Int, offsetX: Float, offsetY: Float) {
    val uTex = GLES20.glGetUniformLocation(program, "uTexture")
    val uOff = GLES20.glGetUniformLocation(program, "uOffset")
    val aPos = GLES20.glGetAttribLocation(program, "aPosition")
    val aUv = GLES20.glGetAttribLocation(program, "aTexCoord")
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
    GLES20.glUniform1i(uTex, 0)
    GLES20.glUniform2f(uOff, offsetX, offsetY)
    val verts = floatArrayOf(-1f, -1f, 0f, 1f, 1f, -1f, 1f, 1f, -1f, 1f, 0f, 0f, 1f, 1f, 1f, 0f)
    val bb = ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
    bb.put(verts).position(0)
    GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, bb)
    GLES20.glEnableVertexAttribArray(aPos)
    val uv = bb.duplicate()
    uv.position(2)
    GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 16, uv)
    GLES20.glEnableVertexAttribArray(aUv)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
  }

  private fun createOesTexture(): Int {
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    return ids[0]
  }

  private fun buildProgram(vertex: String, fragment: String): Int {
    fun load(type: Int, src: String): Int {
      val s = GLES20.glCreateShader(type)
      GLES20.glShaderSource(s, src)
      GLES20.glCompileShader(s)
      return s
    }
    val prog = GLES20.glCreateProgram()
    GLES20.glAttachShader(prog, load(GLES20.GL_VERTEX_SHADER, vertex))
    GLES20.glAttachShader(prog, load(GLES20.GL_FRAGMENT_SHADER, fragment))
    GLES20.glLinkProgram(prog)
    return prog
  }

  companion object {
    private const val VERTEX = """
      attribute vec4 aPosition;
      attribute vec2 aTexCoord;
      uniform vec2 uOffset;
      varying vec2 vTexCoord;
      void main() {
        gl_Position = vec4(aPosition.xy + uOffset, 0.0, 1.0);
        vTexCoord = aTexCoord;
      }
    """
    private const val FRAGMENT = """
      #extension GL_OES_EGL_image_external : require
      precision mediump float;
      varying vec2 vTexCoord;
      uniform samplerExternalOES uTexture;
      void main() { gl_FragColor = texture2D(uTexture, vTexCoord); }
    """
  }
}

private object GpuSlideRenderer {
  private val slideEffects = setOf(
    "slideleft", "slideright", "slideup", "slidedown",
    "coverleft", "coverright", "coverup", "coverdown",
    "pushleft", "pushright", "pushup", "pushdown",
  )

  fun isSlide(effect: String): Boolean = slideEffects.contains(effect.lowercase())

  fun offsets(effect: String, t: Float): Pair<FloatArray, FloatArray> {
    return when (effect.lowercase()) {
      "slideleft", "pushleft", "coverleft" ->
        floatArrayOf(-2f * t, 0f) to floatArrayOf(2f * (1f - t), 0f)
      "slideright", "pushright", "coverright" ->
        floatArrayOf(2f * t, 0f) to floatArrayOf(-2f * (1f - t), 0f)
      "slideup", "pushup", "coverup" ->
        floatArrayOf(0f, 2f * t) to floatArrayOf(0f, -2f * (1f - t))
      "slidedown", "pushdown", "coverdown" ->
        floatArrayOf(0f, -2f * t) to floatArrayOf(0f, 2f * (1f - t))
      else ->
        floatArrayOf(-2f * t, 0f) to floatArrayOf(2f * (1f - t), 0f)
    }
  }
}


/** Continuous composition audio — decode PCM forward; seek only on scrub/cuts. */
@UnstableApi
private class CompositionAudioPlayer(
  private val sourcePath: String,
  private val ranges: List<PackedRange>,
  private val durationUs: Long,
) {
  private val extractor = MediaExtractor()
  private var codec: MediaCodec? = null
  private var track: AudioTrack? = null
  private var inputFormat: MediaFormat? = null
  private var sampleRate = 44100
  private var channelCount = 2
  private val playing = AtomicBoolean(false)
  private var released = false
  private var compositionUs = 0L
  private var lastSourceUs = -1L
  private var lastRangeStart = -1L
  private val thread = HandlerThread("native-timeline-audio").also { it.start() }
  private val handler = Handler(thread.looper)

  fun prepare() {
    extractor.setDataSource(sourcePath)
    var found = -1
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      if (!mime.startsWith("audio/")) continue
      found = i
      inputFormat = format
      sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
      channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
      extractor.selectTrack(i)
      codec = MediaCodec.createDecoderByType(mime).also {
        it.configure(format, null, null, 0)
        it.start()
      }
      break
    }
    if (found < 0) throw IllegalStateException("No audio track")
    val channelConfig = if (channelCount == 1) {
      AudioFormat.CHANNEL_OUT_MONO
    } else {
      AudioFormat.CHANNEL_OUT_STEREO
    }
    val minBuf = AudioTrack.getMinBufferSize(
      sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT,
    ).coerceAtLeast(sampleRate / 10 * channelCount * 2)
    track = AudioTrack.Builder()
      .setAudioAttributes(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
          .build(),
      )
      .setAudioFormat(
        AudioFormat.Builder()
          .setSampleRate(sampleRate)
          .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
          .setChannelMask(channelConfig)
          .build(),
      )
      .setBufferSizeInBytes(minBuf)
      .setTransferMode(AudioTrack.MODE_STREAM)
      .build()
  }

  fun seekTo(compUs: Long) {
    compositionUs = compUs.coerceIn(0L, durationUs)
    lastSourceUs = -1L
    lastRangeStart = -1L
    handler.post {
      try {
        track?.pause()
        track?.flush()
      } catch (_: Exception) {
      }
      val source = sourceUs(compositionUs) ?: return@post
      reopenAt(source)
    }
  }

  fun play() {
    playing.set(true)
    handler.post {
      val source = sourceUs(compositionUs)
      if (source != null) reopenAt(source)
      try {
        track?.play()
      } catch (_: Exception) {
      }
      pump()
    }
  }

  fun pause() {
    playing.set(false)
    handler.post {
      try {
        track?.pause()
        track?.flush()
      } catch (_: Exception) {
      }
    }
  }

  fun release() {
    if (released) return
    released = true
    playing.set(false)
    val latch = CountDownLatch(1)
    handler.post {
      try {
        track?.stop()
      } catch (_: Exception) {
      }
      try {
        track?.release()
      } catch (_: Exception) {
      }
      track = null
      try {
        codec?.stop()
        codec?.release()
      } catch (_: Exception) {
      }
      codec = null
      try {
        extractor.release()
      } catch (_: Exception) {
      }
      latch.countDown()
    }
    latch.await()
    thread.quitSafely()
  }

  private fun pump() {
    if (!playing.get() || released) return
    val t = track ?: return
    val c = codec ?: return
    var loops = 0
    while (playing.get() && !released && loops++ < 8) {
      if (compositionUs >= durationUs) {
        playing.set(false)
        try {
          t.pause()
        } catch (_: Exception) {
        }
        return
      }
      val range = activeRange(compositionUs) ?: break
      val source = sourceUs(compositionUs) ?: break
      if (lastRangeStart != range.compositionStartUs ||
        lastSourceUs < 0L ||
        source + 80_000L < lastSourceUs ||
        source > lastSourceUs + 500_000L
      ) {
        reopenAt(source)
        lastRangeStart = range.compositionStartUs
      }

      val info = MediaCodec.BufferInfo()
      val inIndex = c.dequeueInputBuffer(2_000)
      if (inIndex >= 0) {
        val buffer = c.getInputBuffer(inIndex)!!
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) {
          c.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        } else {
          c.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
          extractor.advance()
        }
      }
      val outIndex = c.dequeueOutputBuffer(info, 2_000)
      if (outIndex >= 0) {
        val outBuf = c.getOutputBuffer(outIndex)
        if (outBuf != null && info.size > 0) {
          val pcm = ByteArray(info.size)
          outBuf.position(info.offset)
          outBuf.get(pcm)
          if (range.volume != 1f) {
            applyVolume(pcm, range.volume)
          }
          t.write(pcm, 0, pcm.size)
          val frameBytes = channelCount * 2
          if (frameBytes > 0) {
            val frames = pcm.size / frameBytes
            val chunkUs = frames * 1_000_000L / sampleRate
            compositionUs = (compositionUs + chunkUs).coerceAtMost(durationUs)
            lastSourceUs = source + chunkUs
          }
        }
        c.releaseOutputBuffer(outIndex, false)
      }
    }
    if (playing.get() && !released) {
      handler.post { pump() }
    }
  }

  private fun activeRange(compUs: Long): PackedRange? {
    return ranges.firstOrNull {
      compUs >= it.compositionStartUs && compUs < it.compositionEndUs
    } ?: ranges.lastOrNull()
  }

  private fun sourceUs(compUs: Long): Long? {
    val r = activeRange(compUs) ?: return null
    val local = compUs - r.compositionStartUs
    return (r.sourceStartUs + local).coerceAtMost(max(r.sourceStartUs, r.sourceEndUs - 1))
  }

  private fun reopenAt(sourceUs: Long) {
    val c = codec ?: return
    extractor.seekTo(sourceUs.coerceAtLeast(0L), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
    try {
      c.flush()
    } catch (_: Exception) {
    }
    lastSourceUs = sourceUs
  }

  private fun applyVolume(pcm: ByteArray, volume: Float) {
    var i = 0
    while (i + 1 < pcm.size) {
      val sample = ((pcm[i].toInt() and 0xff) or (pcm[i + 1].toInt() shl 8)).toShort()
      val scaled = (sample * volume).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
      pcm[i] = (scaled and 0xff).toByte()
      pcm[i + 1] = ((scaled shr 8) and 0xff).toByte()
      i += 2
    }
  }
}

@UnstableApi
private class Media3ClipDecoder(
  private val sourcePath: String,
  private val surface: Surface,
) {
  private val extractor = MediaExtractor()
  private var codec: MediaCodec? = null
  private var lastPtsUs = -1L

  fun start() {
    extractor.setDataSource(sourcePath)
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      if (!MimeTypes.isVideo(mime)) continue
      extractor.selectTrack(i)
      codec = MediaCodec.createDecoderByType(mime).also {
        it.configure(format, surface, null, 0)
        it.start()
      }
      return
    }
    throw IllegalStateException("No video track (Media3)")
  }

  /** Random access — used for scrub / large jumps only. */
  fun seekTo(absoluteUs: Long) {
    val c = codec ?: return
    val targetUs = absoluteUs.coerceAtLeast(0L)
    extractor.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
    try {
      c.flush()
    } catch (_: Exception) {
    }
    lastPtsUs = -1L
    drainUntil(targetUs, maxLoops = 96)
  }

  /** Continuous forward decode during playback. */
  fun seekAndDecode(compositionUs: Long) {
    // Absolute source time for timeline path; transition session passes absolute too after fix.
    advanceTo(compositionUs)
  }

  fun seekAndDecodeAbsolute(absoluteUs: Long) {
    seekTo(absoluteUs)
  }

  fun advanceTo(absoluteUs: Long) {
    val targetUs = absoluteUs.coerceAtLeast(0L)
    if (lastPtsUs >= 0 && targetUs + 40_000L < lastPtsUs) {
      seekTo(targetUs)
      return
    }
    drainUntil(targetUs, maxLoops = 24)
  }

  private fun drainUntil(targetUs: Long, maxLoops: Int) {
    val c = codec ?: return
    val info = MediaCodec.BufferInfo()
    var loops = 0
    while (loops++ < maxLoops) {
      val inIndex = c.dequeueInputBuffer(2_000)
      if (inIndex >= 0) {
        val buffer = c.getInputBuffer(inIndex)!!
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) {
          c.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        } else {
          c.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
          extractor.advance()
        }
      }
      val outIndex = c.dequeueOutputBuffer(info, 2_000)
      if (outIndex >= 0) {
        val render = info.presentationTimeUs >= targetUs - 20_000 ||
          (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
        c.releaseOutputBuffer(outIndex, render)
        if (render) {
          lastPtsUs = info.presentationTimeUs
          if (info.presentationTimeUs >= targetUs - 20_000) return
        }
      }
      if (lastPtsUs >= targetUs - 20_000) return
    }
  }

  fun release() {
    try {
      codec?.stop()
      codec?.release()
    } catch (_: Exception) {
    }
    codec = null
    extractor.release()
  }
}
