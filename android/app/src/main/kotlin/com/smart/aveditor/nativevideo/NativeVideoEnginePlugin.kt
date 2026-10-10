package com.smart.aveditor.nativevideo

import android.content.Context
import android.os.Handler
import android.util.Log
import android.os.Looper
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MultipleInputVideoGraph
import androidx.media3.transformer.CompositionPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Android Native Video Engine.
 * Timeline playback uses one Media3 CompositionPlayer, the same composition album export writes.
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
  private var timeline: TimelineCompositionSession? = null

  companion object {
    const val CHANNEL = "com.smart.aveditor/native_video_engine"
    const val EVENTS = "com.smart.aveditor/native_video_engine/events"

    fun registerWith(engine: FlutterEngine) {
      engine.plugins.add(NativeVideoEnginePlugin())
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

  private fun silenceCodecBufferPool() {
    try {
      Runtime.getRuntime().exec(
        arrayOf("setprop", "log.tag.BufferPoolAccessor2.0", "S"),
      )
    } catch (e: Exception) {
      Log.i("NativeVideoEngine", "buffer pool log silence failed ${e.message}")
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    events.setStreamHandler(null)
    timeline?.release()
    timeline = null
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
        val context = appContext
        val sourcePath = args?.get("sourcePath") as? String
        val segments = args?.get("segments") as? List<*>
        if (args == null || registry == null || context == null ||
          sourcePath == null || segments.isNullOrEmpty()
        ) {
          result.error("bad_args", "prepareTimeline", null)
          return
        }
        val existing = timeline
        if (existing != null) {
          try {
            existing.update(sourcePath, segments)
            result.success(
              mapOf(
                "textureId" to existing.textureId,
                "durationMs" to existing.durationMs,
                "width" to existing.width,
                "height" to existing.height,
              ),
            )
          } catch (e: Exception) {
            Log.e("NativeVideoEngine", "updateTimeline failed", e)
            result.error("prepare_failed", e.message, null)
          }
          return
        }
        try {
          val preview = NativeVideoEngineMedia.buildTimelinePreview(sourcePath, segments)
          val created = registry.createSurfaceTexture()
          try {
            val playing = TimelineCompositionSession(
              context = context,
              surfaceTextureEntry = created,
              preview = preview,
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
              "durationMs" to preview.durationMs,
              "width" to preview.width,
              "height" to preview.height,
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
        val failure = playing.play()
        if (failure != null) {
          Log.e("NativeVideoEngine", "play failed $failure")
          result.error("play_failed", failure, null)
        } else {
          result.success(playing.playbackSnapshot())
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

/**
 * Plays the export [androidx.media3.transformer.Composition] into a Flutter texture.
 * Transition drawing is [TransitionCompositor], the same object graph album export writes.
 */
@UnstableApi
internal fun timelineVideoInputs(preview: TimelinePreview): Int {
  return preview.composition.sequences.count { sequence ->
    sequence.trackTypes.contains(C.TRACK_TYPE_VIDEO)
  }
}

internal fun newTimelinePlayer(context: Context, preview: TimelinePreview): CompositionPlayer {
  return CompositionPlayer.Builder(context).apply {
    setLooper(Looper.getMainLooper())
    val videoInputs = timelineVideoInputs(preview)
    // A single video sequence plays through the default graph. The multi-input
    // graph is what accepts TransitionCompositor, and it stalls a one-video preview.
    if (videoInputs > 1) {
      setVideoGraphFactory(MultipleInputVideoGraph.Factory())
    }
    Log.i(
      "NativeVideoEngine",
      "timeline graph=${if (videoInputs > 1) "multiple" else "single"} videoInputs=$videoInputs",
    )
  }.build()
}

/**
 * Plays the export [androidx.media3.transformer.Composition] into a Flutter texture.
 * Transition drawing is [TransitionCompositor], the same object graph album export writes.
 */
@UnstableApi
private class TimelineCompositionSession(
  context: Context,
  private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
  preview: TimelinePreview,
  private val onEvent: (Map<String, Any>) -> Unit,
) {
  private val handler = Handler(Looper.getMainLooper())
  private val appContext = context.applicationContext
  private val mix = preview.mix ?: TimelineMix()
  private var preview = preview

  init {
    mix.onDrawnMs = { ms -> handler.post { onSeekFrameDrawn(ms) } }
  }
  private var player = newTimelinePlayer(appContext, preview)
  private var multiGraph = timelineVideoInputs(preview) > 1
  private var acceptedFirstFrame = false
  /** One multi-input setComposition at a time. A second release while the first is starting times out. */
  private var placeInFlight = false
  private var pendingPlaceMs = -1L
  private var placeDebounce: Runnable? = null
  /** Position passed to the last seekTo. The drawn-frame callback pauses once it matches. */
  private var issuedSeekMs = -1L
  /** A multi-input seek is in flight. Another seekTo before its frame flushes the picture away. */
  private var scrubbing = false
  private var settlePause: Runnable? = null
  private var scrubTimeout: Runnable? = null
  /** Non-zero while a paused seek still needs one frame on the Flutter texture. */
  private var pausedReveal = 0
  private var surface: Surface? = null
  private var released = false
  private var prerollGate: ((Boolean) -> Unit)? = null
  private var prerollEarly: Runnable? = null
  private var prerollTimeout: Runnable? = null
  private var playbackRequested = false
  private var blendLoggedInside = false
  private var blendLogAtMs = 0L
  private var blendTickPos = -1L
  private val tick = object : Runnable {
    override fun run() {
      if (released || !playbackRequested) return
      noteBlendClock()
      if (player.playbackState == Player.STATE_ENDED) {
        val atEnd = player.currentPosition >= preview.durationMs - 80
        if (!atEnd) {
          handler.postDelayed(this, 33L)
          return
        }
        playbackRequested = false
        emitPosition()
        onEvent(mapOf("type" to "completed"))
        return
      }
      // Play seeks first, so this tick often runs while the player is still
      // buffering. Dropping it here left the picture moving and the timeline stuck.
      if (!player.isPlaying) {
        handler.postDelayed(this, 33L)
        return
      }
      emitPosition()
      handler.postDelayed(this, 33L)
    }
  }
  private val listener = object : Player.Listener {
    override fun onEvents(player: Player, events: Player.Events) {
      if (released) return
      if (events.contains(Player.EVENT_RENDERED_FIRST_FRAME) ||
        (player.playbackState == Player.STATE_READY &&
          events.contains(Player.EVENT_POSITION_DISCONTINUITY))
      ) {
        acceptedFirstFrame = true
        finishPreroll(true)
      }
      if (events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED) &&
        player.playbackState == Player.STATE_ENDED
      ) {
        val atEnd = player.currentPosition >= preview.durationMs - 80
        if (!atEnd) {
          Log.i(
            "NativeVideoEngine",
            "timeline ended early pos=${player.currentPosition} " +
              "durationMs=${preview.durationMs} playWhenReady=${player.playWhenReady} " +
              "isPlaying=${player.isPlaying}",
          )
          return
        }
        Log.i(
          "NativeVideoEngine",
          "timeline ended atEnd pos=${player.currentPosition} durationMs=${preview.durationMs}",
        )
        playbackRequested = false
        handler.removeCallbacks(tick)
        emitPosition()
        onEvent(mapOf("type" to "completed"))
      }
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
      if (playbackState == Player.STATE_READY) acceptedFirstFrame = true
      Log.i(
        "NativeVideoEngine",
        "timeline state=${stateName(playbackState)} pos=${player.currentPosition} " +
          "playWhenReady=${player.playWhenReady} isPlaying=${player.isPlaying}" +
          blendMark(player.currentPosition),
      )
      if (playbackState == Player.STATE_READY) placeInFlight = false
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
      Log.i(
        "NativeVideoEngine",
        "timeline isPlaying=$isPlaying state=${stateName(player.playbackState)} " +
          "pos=${player.currentPosition} playWhenReady=${player.playWhenReady}",
      )
    }

    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
      Log.i(
        "NativeVideoEngine",
        "timeline playWhenReady=$playWhenReady reason=${playWhenReadyReason(reason)} " +
          "state=${stateName(player.playbackState)} pos=${player.currentPosition}",
      )
    }

    override fun onPlayerError(error: PlaybackException) {
      Log.e(
        "NativeVideoEngine",
        "timeline playback failed code=${error.errorCode} ${error.errorCodeName}",
        error,
      )
      playbackRequested = false
      placeInFlight = false
      pausedReveal = 0
      handler.removeCallbacks(tick)
      finishPreroll(false)
    }
  }

  val textureId: Long
    get() = surfaceTextureEntry.id()

  val durationMs: Int
    get() = preview.durationMs

  val width: Int
    get() = preview.width

  val height: Int
    get() = preview.height

  fun update(sourcePath: String, segments: List<*>) {
    if (released) return
    val layoutChanged = !NativeVideoEngineMedia.sameMixerLayout(mix, segments)
    val next = NativeVideoEngineMedia.buildTimelinePreview(sourcePath, segments, mix)
    val pos = player.currentPosition.coerceIn(0L, next.durationMs.toLong())
    val resume = playbackRequested
    preview = next
    val nextMulti = timelineVideoInputs(next) > 1
    if (nextMulti != multiGraph) {
      // The graph is fixed when the player is built. A plain clip uses one
      // sequence. The first transition is the only time this player is replaced,
      // on the same texture.
      reopenPlayer(next, pos, resume)
      return
    }
    if (!layoutChanged) {
      Log.i(
        "NativeVideoEngine",
        "timeline mix data windows=${mix.blends.size} pos=$pos",
      )
      return
    }
    Log.i(
      "NativeVideoEngine",
      "timeline mix inputs ${next.width}x${next.height} " +
        "durationMs=${next.durationMs} sequences=${next.composition.sequences.size}",
    )
    if (multiGraph && acceptedFirstFrame) {
      Log.i("NativeVideoEngine", "timeline mix place setComposition to=$pos")
      player.setComposition(next.composition, pos)
    } else {
      player.setComposition(next.composition)
      if (pos > 0L) player.seekTo(pos)
    }
    prepareIfIdle()
    if (resume) player.play()
  }

  private fun reopenPlayer(next: TimelinePreview, pos: Long, resume: Boolean) {
    clearPrerollWaits()
    finishPreroll(false)
    player.removeListener(listener)
    player.release()
    surface?.release()
    preview = next
    multiGraph = timelineVideoInputs(next) > 1
    player = newTimelinePlayer(appContext, next)
    val texture = surfaceTextureEntry.surfaceTexture()
    texture.setDefaultBufferSize(next.width, next.height)
    val output = Surface(texture)
    surface = output
    player.addListener(listener)
    player.setVideoSurface(output, Size(next.width, next.height))
    Log.i(
      "NativeVideoEngine",
      "timeline reopen graph=${if (multiGraph) "multiple" else "single"} " +
        "sequences=${next.composition.sequences.size}",
    )
    acceptedFirstFrame = false
    placeInFlight = false
    pendingPlaceMs = -1L
    issuedSeekMs = -1L
    pausedReveal = 0
    scrubbing = false
    placeDebounce?.let { handler.removeCallbacks(it) }
    placeDebounce = null
    if (pos > 0L) {
      player.setComposition(next.composition, pos)
    } else {
      player.setComposition(next.composition)
    }
    // A new player still needs prepare(). setComposition(composition, pos) returns
    // before the sequence players are prepared, which leaves playback idle.
    prepareIfIdle()
    if (resume) {
      playbackRequested = true
      player.play()
      handler.removeCallbacks(tick)
      handler.post(tick)
    }
  }

  fun start() {
    val texture = surfaceTextureEntry.surfaceTexture()
    texture.setDefaultBufferSize(preview.width, preview.height)
    val output = Surface(texture)
    surface = output
    player.addListener(listener)
    player.setVideoSurface(output, Size(preview.width, preview.height))
    Log.i(
      "NativeVideoEngine",
      "timeline setComposition ${preview.width}x${preview.height} " +
        "durationMs=${preview.durationMs} sequences=${preview.composition.sequences.size}",
    )
    player.setComposition(preview.composition)
    player.prepare()
    Log.i("NativeVideoEngine", "timeline prepared state=${stateName(player.playbackState)}")
  }

  private fun noteBlendClock() {
    val pos = player.currentPosition
    val inside = mix.blends.firstOrNull { pos >= it.startMs && pos < it.startMs + it.durationMs }
    val near = inside ?: mix.blends.firstOrNull {
      pos + 500 >= it.startMs && pos < it.startMs + it.durationMs + 200
    }
    if (inside != null && !blendLoggedInside) {
      Log.i(
        "NativeVideoEngine",
        "timeline blend enter pos=$pos window=${inside.startMs}+${inside.durationMs} " +
          "state=${stateName(player.playbackState)} isPlaying=${player.isPlaying} " +
          "playWhenReady=${player.playWhenReady}",
      )
      blendLogAtMs = 0L
    } else if (inside == null && blendLoggedInside) {
      Log.i(
        "NativeVideoEngine",
        "timeline blend leave pos=$pos state=${stateName(player.playbackState)} " +
          "isPlaying=${player.isPlaying} playWhenReady=${player.playWhenReady}",
      )
    }
    blendLoggedInside = inside != null
    if (near == null) {
      blendTickPos = pos
      return
    }
    val now = android.os.SystemClock.uptimeMillis()
    if (now - blendLogAtMs < 250L) {
      blendTickPos = pos
      return
    }
    blendLogAtMs = now
    val delta = if (blendTickPos < 0L) 0L else pos - blendTickPos
    Log.i(
      "NativeVideoEngine",
      "timeline blend pos=$pos delta=$delta window=${near.startMs}+${near.durationMs} " +
        "state=${stateName(player.playbackState)} isPlaying=${player.isPlaying} " +
        "playWhenReady=${player.playWhenReady}",
    )
    blendTickPos = pos
  }

  private fun blendMark(pos: Long): String {
    val window = mix.blends.firstOrNull {
      pos + 500 >= it.startMs && pos < it.startMs + it.durationMs + 200
    } ?: return ""
    return " blend=${window.startMs}+${window.durationMs}"
  }

  private fun stateName(playbackState: Int): String {
    return when (playbackState) {
      Player.STATE_IDLE -> "idle"
      Player.STATE_BUFFERING -> "buffering"
      Player.STATE_READY -> "ready"
      Player.STATE_ENDED -> "ended"
      else -> playbackState.toString()
    }
  }

  /**
   * Seeks the open player. Two sequences only draw the new frame while rendering
   * is on, so a paused scrub keeps rendering until [onSeekFrameDrawn] matches.
   */
  private fun placeAt(landed: Long) {
    if (!multiGraph || !acceptedFirstFrame) {
      Log.i(
        "NativeVideoEngine",
        "timeline seek to=$landed state=${stateName(player.playbackState)}",
      )
      player.seekTo(landed)
      return
    }
    pendingPlaceMs = landed
    settlePause?.let { handler.removeCallbacks(it) }
    settlePause = null
    if (!playbackRequested) holdReveal()
    if (scrubbing) return
    scheduleSeek()
  }

  private fun scheduleSeek() {
    placeDebounce?.let { handler.removeCallbacks(it) }
    val run = Runnable {
      placeDebounce = null
      if (released || scrubbing) return@Runnable
      val target = pendingPlaceMs
      if (target < 0L) return@Runnable
      scrubbing = true
      issuedSeekMs = target
      Log.i(
        "NativeVideoEngine",
        "timeline seekTo to=$target state=${stateName(player.playbackState)} " +
          "playWhenReady=${player.playWhenReady}",
      )
      player.seekTo(target)
      armScrubTimeout()
    }
    placeDebounce = run
    handler.postDelayed(run, 40L)
  }

  private fun armScrubTimeout() {
    scrubTimeout?.let { handler.removeCallbacks(it) }
    val timeout = Runnable {
      scrubTimeout = null
      if (released || !scrubbing) return@Runnable
      Log.i(
        "NativeVideoEngine",
        "timeline seek retry pending=$pendingPlaceMs issued=$issuedSeekMs " +
          "state=${stateName(player.playbackState)}",
      )
      scrubbing = false
      if (pendingPlaceMs >= 0L && !playbackRequested) scheduleSeek()
    }
    scrubTimeout = timeout
    handler.postDelayed(timeout, 350L)
  }

  private fun flushPlace() {
    placeDebounce?.let { handler.removeCallbacks(it) }
    settlePause?.let { handler.removeCallbacks(it) }
    scrubTimeout?.let { handler.removeCallbacks(it) }
    placeDebounce = null
    settlePause = null
    scrubTimeout = null
    scrubbing = false
    val target = pendingPlaceMs
    pendingPlaceMs = -1L
    issuedSeekMs = -1L
    pausedReveal = 0
    if (target < 0L || released) return
    if (kotlin.math.abs(player.currentPosition - target) <= 40L) return
    Log.i(
      "NativeVideoEngine",
      "timeline seekTo to=$target state=${stateName(player.playbackState)} play=true",
    )
    player.seekTo(target)
  }

  /** Rendering stays on until the seeked frame is drawn. */
  private fun holdReveal() {
    if (released || playbackRequested || player.playWhenReady) return
    pausedReveal += 1
    Log.i(
      "NativeVideoEngine",
      "timeline seek reveal token=$pausedReveal pos=${player.currentPosition} " +
        "state=${stateName(player.playbackState)}",
    )
    player.play()
  }

  private fun onSeekFrameDrawn(ms: Long) {
    if (!scrubbing || playbackRequested || released) return
    val issued = issuedSeekMs
    if (issued < 0L || kotlin.math.abs(ms - issued) > 180L) return
    scrubTimeout?.let { handler.removeCallbacks(it) }
    scrubTimeout = null
    scrubbing = false
    val pending = pendingPlaceMs
    if (pending >= 0L && kotlin.math.abs(pending - ms) > 80L) {
      Log.i("NativeVideoEngine", "timeline seek next drawn=$ms pending=$pending")
      scheduleSeek()
      return
    }
    val pause = Runnable {
      settlePause = null
      if (released || playbackRequested || scrubbing) return@Runnable
      val latest = pendingPlaceMs
      if (latest >= 0L && kotlin.math.abs(latest - ms) > 80L) {
        scheduleSeek()
        return@Runnable
      }
      Log.i(
        "NativeVideoEngine",
        "timeline seek frame drawn ms=$ms target=$issued " +
          "state=${stateName(player.playbackState)}",
      )
      pendingPlaceMs = -1L
      issuedSeekMs = -1L
      pausedReveal = 0
      player.pause()
    }
    settlePause = pause
    handler.postDelayed(pause, 90L)
  }

  /** Media3 ignores prepare() unless the player is idle, so a playing frame is left alone. */
  private fun prepareIfIdle() {
    if (player.playbackState != Player.STATE_IDLE) return
    Log.i(
      "NativeVideoEngine",
      "timeline prepare idle pos=${player.currentPosition} " +
        "error=${player.playerError?.errorCodeName}",
    )
    player.prepare()
    Log.i(
      "NativeVideoEngine",
      "timeline prepare done state=${stateName(player.playbackState)} " +
        "error=${player.playerError?.errorCodeName}",
    )
  }

  private fun playWhenReadyReason(reason: Int): String {
    return when (reason) {
      Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> "user"
      Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> "audioFocus"
      Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> "noisy"
      Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE -> "remote"
      Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM -> "endOfItem"
      Player.PLAY_WHEN_READY_CHANGE_REASON_SUPPRESSED_TOO_LONG -> "suppressed"
      else -> reason.toString()
    }
  }

  fun play(): String? {
    Log.i(
      "NativeVideoEngine",
      "timeline play released=$released state=${stateName(player.playbackState)} " +
        "pos=${player.currentPosition} playWhenReady=${player.playWhenReady}",
    )
    if (released) {
      logPlayResult("released")
      return "released"
    }
    playbackRequested = true
    pausedReveal = 0
    flushPlace()
    prepareIfIdle()
    if (player.playbackState == Player.STATE_IDLE || player.playerError != null) {
      // prepare() left the player idle. A stuck error keeps Media3 in idle, so
      // play() cannot start until this player is replaced on the same texture.
      Log.i(
        "NativeVideoEngine",
        "timeline play reopens idle error=${player.playerError?.errorCodeName} " +
          "pos=${player.currentPosition}",
      )
      val pos = (if (pendingPlaceMs >= 0L) pendingPlaceMs else player.currentPosition)
        .coerceIn(0L, preview.durationMs.toLong())
      pendingPlaceMs = -1L
      reopenPlayer(preview, pos, true)
    } else {
      player.play()
      handler.removeCallbacks(tick)
      handler.post(tick)
    }
    val failure = playFailure()
    logPlayResult(failure)
    if (failure != null) {
      playbackRequested = false
      handler.removeCallbacks(tick)
      onEvent(mapOf("type" to "playing", "playing" to false))
      return failure
    }
    onEvent(mapOf("type" to "playing", "playing" to true))
    return null
  }

  fun playbackSnapshot(): Map<String, Any> {
    return mapOf(
      "state" to stateName(player.playbackState),
      "pos" to player.currentPosition,
      "playWhenReady" to player.playWhenReady,
      "isPlaying" to player.isPlaying,
      "error" to (player.playerError?.errorCodeName ?: ""),
    )
  }

  private fun playFailure(): String? {
    val error = player.playerError
    if (error != null) {
      return "error=${error.errorCodeName} message=${error.message} " +
        "state=${stateName(player.playbackState)} pos=${player.currentPosition}"
    }
    if (player.playbackState == Player.STATE_IDLE) {
      return "state=idle pos=${player.currentPosition} " +
        "playWhenReady=${player.playWhenReady}"
    }
    if (player.playbackState == Player.STATE_ENDED) {
      return "state=ended pos=${player.currentPosition} duration=${preview.durationMs}"
    }
    return null
  }

  private fun logPlayResult(failure: String?) {
    Log.i(
      "NativeVideoEngine",
      "timeline play result state=${stateName(player.playbackState)} " +
        "pos=${player.currentPosition} playWhenReady=${player.playWhenReady} " +
        "isPlaying=${player.isPlaying} error=${player.playerError?.errorCodeName} " +
        "failure=${failure ?: "none"}",
    )
  }

  fun pause() {
    Log.i(
      "NativeVideoEngine",
      "timeline pause state=${stateName(player.playbackState)} " +
        "pos=${player.currentPosition} playWhenReady=${player.playWhenReady} " +
        "isPlaying=${player.isPlaying}",
    )
    if (released) return
    playbackRequested = false
    scrubbing = false
    pendingPlaceMs = -1L
    issuedSeekMs = -1L
    settlePause?.let { handler.removeCallbacks(it) }
    scrubTimeout?.let { handler.removeCallbacks(it) }
    settlePause = null
    scrubTimeout = null
    player.pause()
    handler.removeCallbacks(tick)
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  fun seekToMs(ms: Long) {
    if (released) return
    val landed = ms.coerceIn(0L, preview.durationMs.toLong())
    if (kotlin.math.abs(player.currentPosition - landed) <= 40L) {
      Log.i("NativeVideoEngine", "seek skipped already at $landed")
      onEvent(mapOf("type" to "position", "positionMs" to landed.toInt()))
      return
    }
    Log.i(
      "NativeVideoEngine",
      "timeline seek pauses from=${player.currentPosition} to=$landed " +
        "state=${stateName(player.playbackState)} reveal=$pausedReveal",
    )
    if (!multiGraph || !acceptedFirstFrame) player.pause()
    handler.removeCallbacks(tick)
    placeAt(landed)
    onEvent(mapOf("type" to "playing", "playing" to false))
    onEvent(mapOf("type" to "position", "positionMs" to landed.toInt()))
  }

  fun prerollToMs(ms: Long, done: (Boolean) -> Unit) {
    if (released) {
      done(false)
      return
    }
    clearPrerollWaits()
    finishPreroll(false)
    val landed = ms.coerceIn(0L, preview.durationMs.toLong())
    prerollGate = done
    if (kotlin.math.abs(player.currentPosition - landed) <= 40L) {
      Log.i("NativeVideoEngine", "preroll skipped already at $landed")
      val early = Runnable {
        if (!released && player.playbackState == Player.STATE_READY) finishPreroll(true)
      }
      val timeout = Runnable {
        if (!released) finishPreroll(true)
      }
      prerollEarly = early
      prerollTimeout = timeout
      handler.postDelayed(early, 120L)
      handler.postDelayed(timeout, 1500L)
      return
    }
    Log.i(
      "NativeVideoEngine",
      "timeline preroll pauses from=${player.currentPosition} to=$landed " +
        "state=${stateName(player.playbackState)} reveal=$pausedReveal",
    )
    if (!multiGraph || !acceptedFirstFrame) player.pause()
    handler.removeCallbacks(tick)
    placeAt(landed)
    try {
      player.experimentalRedrawLastFrame()
    } catch (_: Exception) {
    }
    val early = Runnable {
      if (!released && player.playbackState == Player.STATE_READY) finishPreroll(true)
    }
    val timeout = Runnable {
      if (!released) finishPreroll(player.playbackState == Player.STATE_READY)
    }
    prerollEarly = early
    prerollTimeout = timeout
    handler.postDelayed(early, 120L)
    handler.postDelayed(timeout, 1500L)
  }

  fun release() {
    if (released) return
    released = true
    playbackRequested = false
    placeInFlight = false
    pendingPlaceMs = -1L
    issuedSeekMs = -1L
    pausedReveal = 0
    scrubbing = false
    settlePause?.let { handler.removeCallbacks(it) }
    scrubTimeout?.let { handler.removeCallbacks(it) }
    settlePause = null
    scrubTimeout = null
    mix.onDrawnMs = null
    placeDebounce?.let { handler.removeCallbacks(it) }
    placeDebounce = null
    clearPrerollWaits()
    finishPreroll(false)
    handler.removeCallbacks(tick)
    player.removeListener(listener)
    player.release()
    surface?.release()
    surface = null
    surfaceTextureEntry.release()
  }

  private fun clearPrerollWaits() {
    prerollEarly?.let { handler.removeCallbacks(it) }
    prerollTimeout?.let { handler.removeCallbacks(it) }
    prerollEarly = null
    prerollTimeout = null
  }

  private fun emitPosition() {
    val ms = player.currentPosition.coerceAtLeast(0L).toInt()
    onEvent(mapOf("type" to "position", "positionMs" to ms))
  }

  private fun finishPreroll(ready: Boolean) {
    val gate = prerollGate ?: return
    prerollGate = null
    emitPosition()
    gate(ready)
  }
}

