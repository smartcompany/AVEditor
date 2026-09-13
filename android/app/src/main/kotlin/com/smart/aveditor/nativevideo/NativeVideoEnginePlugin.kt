package com.smart.aveditor.nativevideo

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
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
 *   ├── Media3 (format / timing helpers + demux path)
 *   └── GPU Renderer (OpenGL ES slide/push conveyor)
 *
 * Exposed to Flutter through [NativeVideoEnginePlugin] bridge.
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
  private var session: TransitionEngineSession? = null

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

/** Media3-timed dual decode + GPU slide session. */
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
) {
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
        outDecoder = Media3ClipDecoder(sourcePath, outgoingStartUs, outgoingEndUs, outSurface!!)
        inDecoder = Media3ClipDecoder(sourcePath, incomingStartUs, incomingEndUs, inSurface!!)
        outDecoder!!.start()
        inDecoder!!.start()
        outDecoder!!.seekAndDecode(0)
        inDecoder!!.seekAndDecode(0)
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

  fun play() {
    playing.set(true)
    startWallNs = System.nanoTime()
    startPosUs = positionUs
    onEvent(mapOf("type" to "playing", "playing" to true))
    scheduleTick()
  }

  fun pause() {
    playing.set(false)
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  fun seekToMs(ms: Long) {
    val us = (ms * 1000L).coerceIn(0L, durationUs)
    positionUs = us
    startWallNs = System.nanoTime()
    startPosUs = us
    glHandler.post {
      outDecoder?.seekAndDecode(us)
      inDecoder?.seekAndDecode(us)
      val t = if (durationUs > 0) us.toFloat() / durationUs else 1f
      drawFrame(t.coerceIn(0f, 1f))
      onEvent(mapOf("type" to "position", "positionMs" to (us / 1000L).toInt()))
    }
  }

  fun release() {
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
      outDecoder?.seekAndDecode(positionUs)
      inDecoder?.seekAndDecode(positionUs)
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

/** GPU Renderer — CapCut-style conveyor offsets in clip space. */
private object GpuSlideRenderer {
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

/**
 * Media3-aware clip decoder: demux via MediaExtractor using Media3 mime
 * helpers, decode with MediaCodec into a Surface for the GPU renderer.
 */
@UnstableApi
private class Media3ClipDecoder(
  private val sourcePath: String,
  private val startUs: Long,
  private val endUs: Long,
  private val surface: Surface,
) {
  private val extractor = MediaExtractor()
  private var codec: MediaCodec? = null
  private var windowDurationUs = max(1L, endUs - startUs)

  fun start() {
    extractor.setDataSource(sourcePath)
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      if (!MimeTypes.isVideo(mime)) continue
      extractor.selectTrack(i)
      // Align seek with Media3 timebase (microseconds).
      format.setLong(MediaFormat.KEY_DURATION, windowDurationUs)
      codec = MediaCodec.createDecoderByType(mime).also {
        it.configure(format, surface, null, 0)
        it.start()
      }
      return
    }
    throw IllegalStateException("No video track (Media3)")
  }

  fun seekAndDecode(compositionUs: Long) {
    val c = codec ?: return
    val targetUs = startUs + compositionUs.coerceIn(0L, windowDurationUs)
    extractor.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
    val info = MediaCodec.BufferInfo()
    var inputDone = false
    var outputDone = false
    var safety = 0
    while (!outputDone && safety++ < 64) {
      if (!inputDone) {
        val inIndex = c.dequeueInputBuffer(10_000)
        if (inIndex >= 0) {
          val buffer = c.getInputBuffer(inIndex)!!
          val sampleSize = extractor.readSampleData(buffer, 0)
          if (sampleSize < 0 || extractor.sampleTime > endUs + 50_000) {
            c.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputDone = true
          } else {
            c.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
            extractor.advance()
          }
        }
      }
      val outIndex = c.dequeueOutputBuffer(info, 10_000)
      if (outIndex >= 0) {
        val render = info.presentationTimeUs >= targetUs - 40_000 ||
          (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
        c.releaseOutputBuffer(outIndex, render)
        if (render) outputDone = true
      }
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
