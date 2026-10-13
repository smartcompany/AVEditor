package com.smart.aveditor.nativevideo

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * Plays the original file with ffmpeg when ExoPlayer cannot.
 * Timeline position stays packed segment time. The decoder seeks in source time.
 */
internal class FfmpegTimelineSession(
  private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
  private var sourcePath: String,
  segments: List<*>,
  previewWidth: Int,
  previewHeight: Int,
  private val onEvent: (Map<String, Any>) -> Unit,
) : TimelineSession {
  private val handler = Handler(Looper.getMainLooper())
  private val mix = TimelineMix()
  private val presenter = FfmpegTransitionPresenter(mix)
  private var pieces = piecesOf(segments)
  private var player = FfmpegPlayer(sourcePath)
  private var surface: Surface? = null
  private var released = false
  private var playing = false
  private var endedSent = false
  private var refineMs = 0L
  private var refinePending = false
  private val refine = Runnable {
    refinePending = false
    if (released || playing) return@Runnable
    player.seekExact(refineMs, wait = false)
  }

  override val usesFfmpeg: Boolean = true
  override val textureId: Long
    get() = surfaceTextureEntry.id()
  override var durationMs: Int = packedDuration(pieces)
  override var width: Int = previewWidth.coerceAtLeast(2)
  override var height: Int = previewHeight.coerceAtLeast(2)

  init {
    NativeVideoEngineMedia.fillPlaybackMix(mix, sourcePath, segments)
    bindPlayer()
  }

  private val tick = object : Runnable {
    override fun run() {
      if (released || !playing) return
      val source = player.positionMs()
      skipGap(source)
      val packed = packedOf(player.positionMs()).coerceIn(0L, durationMs.toLong())
      onEvent(mapOf("type" to "position", "positionMs" to packed.toInt()))
      if (player.ended() && !endedSent) {
        endedSent = true
        playing = false
        onEvent(mapOf("type" to "completed"))
        return
      }
      handler.postDelayed(this, 40L)
    }
  }

  override fun update(sourcePath: String, segments: List<*>) {
    if (released) return
    pieces = piecesOf(segments)
    durationMs = packedDuration(pieces)
    NativeVideoEngineMedia.fillPlaybackMix(mix, sourcePath, segments)
    if (sourcePath != this.sourcePath) {
      this.sourcePath = sourcePath
      player.release()
      player = FfmpegPlayer(sourcePath)
      bindPlayer()
      player.setSurface(null, width, height)
    }
  }

  private fun bindPlayer() {
    player.onFrame = { buffer, w, h, pts ->
      presenter.draw(buffer, w, h, packedOf(pts))
    }
    player.onGlRelease = { presenter.releaseGl() }
  }

  override fun start() {
    val texture = surfaceTextureEntry.surfaceTexture()
    texture.setDefaultBufferSize(width, height)
    val output = Surface(texture)
    surface = output
    presenter.setSurface(output)
    player.setSurface(null, width, height)
    val start = pieces.firstOrNull()?.sourceStart ?: 0L
    player.seekExact(start, wait = true)
    Log.i(
      "NativeVideoEngine",
      "ffmpeg player ${width}x$height durationMs=$durationMs pieces=${pieces.size} " +
        "blends=${mix.blends.size}",
    )
  }

  override fun play(): String? {
    if (released) return "released"
    handler.removeCallbacks(refine)
    if (player.ended()) {
      val start = pieces.firstOrNull()?.sourceStart ?: 0L
      refinePending = false
      player.seekExact(start, wait = false)
    } else if (refinePending) {
      refinePending = false
      player.seekExact(refineMs, wait = false)
    }
    endedSent = false
    playing = true
    player.play()
    handler.removeCallbacks(tick)
    handler.post(tick)
    onEvent(mapOf("type" to "playing", "playing" to true))
    return null
  }

  override fun playbackSnapshot(): Map<String, Any> {
    return mapOf(
      "state" to "ready",
      "pos" to packedOf(player.positionMs()),
      "playWhenReady" to playing,
      "isPlaying" to playing,
      "error" to "",
    )
  }

  override fun pause() {
    if (released) return
    playing = false
    player.pause()
    handler.removeCallbacks(tick)
    onEvent(mapOf("type" to "playing", "playing" to false))
  }

  override fun seekToMs(ms: Long) {
    if (released) return
    val landed = ms.coerceIn(0L, durationMs.toLong())
    playing = false
    player.pause()
    handler.removeCallbacks(tick)
    handler.removeCallbacks(refine)
    refineMs = sourceOf(landed)
    refinePending = true
    player.seek(refineMs)
    handler.postDelayed(refine, 160L)
    onEvent(mapOf("type" to "playing", "playing" to false))
    onEvent(mapOf("type" to "position", "positionMs" to landed.toInt()))
  }

  override fun prerollToMs(ms: Long, done: (Boolean) -> Unit) {
    if (released) {
      done(false)
      return
    }
    val landed = ms.coerceIn(0L, durationMs.toLong())
    handler.removeCallbacks(refine)
    refinePending = false
    player.seekExact(sourceOf(landed), wait = true)
    onEvent(mapOf("type" to "position", "positionMs" to landed.toInt()))
    done(true)
  }

  override fun release() {
    if (released) return
    released = true
    playing = false
    handler.removeCallbacks(tick)
    handler.removeCallbacks(refine)
    presenter.close()
    player.release()
    surface?.release()
    surface = null
    surfaceTextureEntry.release()
  }

  private fun skipGap(sourceMs: Long) {
    if (pieceAt(sourceMs) != null) return
    val next = pieces.firstOrNull { it.sourceStart > sourceMs } ?: return
    player.seekExact(next.sourceStart, wait = false)
  }

  private data class Piece(val packedStart: Long, val sourceStart: Long, val duration: Long)

  private fun pieceAt(sourceMs: Long): Piece? {
    return pieces.firstOrNull {
      sourceMs >= it.sourceStart && sourceMs < it.sourceStart + it.duration
    }
  }

  private fun packedOf(sourceMs: Long): Long {
    val piece = pieceAt(sourceMs)
    if (piece != null) return piece.packedStart + (sourceMs - piece.sourceStart)
    val next = pieces.firstOrNull { it.sourceStart > sourceMs }
    if (next != null) return next.packedStart
    return durationMs.toLong()
  }

  private fun sourceOf(packedMs: Long): Long {
    val piece = pieces.firstOrNull { packedMs < it.packedStart + it.duration }
      ?: pieces.lastOrNull()
      ?: return packedMs
    val into = (packedMs - piece.packedStart).coerceAtLeast(0L)
    return piece.sourceStart + into.coerceAtMost(piece.duration)
  }

  companion object {
    private fun piecesOf(segments: List<*>): List<Piece> {
      var packed = 0L
      val out = ArrayList<Piece>()
      for (raw in segments) {
        val segment = raw as? Map<*, *> ?: continue
        val start = (segment["startMs"] as? Number)?.toLong() ?: 0L
        val end = (segment["endMs"] as? Number)?.toLong() ?: start
        val duration = (end - start).coerceAtLeast(0L)
        if (duration == 0L) continue
        out.add(Piece(packed, start, duration))
        packed += duration
      }
      return out
    }

    private fun packedDuration(pieces: List<Piece>): Int {
      val total = pieces.sumOf { it.duration }
      return total.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }
  }
}
