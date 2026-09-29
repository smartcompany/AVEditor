package com.smart.aveditor.nativevideo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Looper
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.nio.ByteOrder
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Probe / waveform / export helpers — Media3 + MediaCodec (no FFmpeg). */
@UnstableApi
object NativeVideoEngineMedia {
  private var activeTransformer: androidx.media3.transformer.Transformer? = null
  private var activeOutput: File? = null
  private var progressHandler: android.os.Handler? = null
  private var progressTick: Runnable? = null
  private var cancelRequested = false

  fun cancelExport() {
    cancelRequested = true
    progressTick?.let { progressHandler?.removeCallbacks(it) }
    activeTransformer?.cancel()
    activeOutput?.delete()
  }

  fun probe(path: String): Map<String, Any> {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(path)
      val durationMs =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
          ?: 0L
      val width =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
          ?: 1080
      val height =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
          ?: 1920
      val hasAudio =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
      return mapOf(
        "hasAudio" to hasAudio,
        "durationMs" to durationMs.toInt(),
        "width" to max(1, width),
        "height" to max(1, height),
      )
    } finally {
      retriever.release()
    }
  }

  fun decodeWaveform(path: String, peakCount: Int): Map<String, Any> {
    // Lightweight amplitude estimate from MediaMetadataRetriever embedded picture
    // is not available for audio; use MediaExtractor PCM via MediaCodec when possible.
    // Fallback: uniform silence peaks so UI still renders.
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(path)
      val durationMs =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
          ?: 0L
      val peaks = WaveformDecoder.decodePeaks(path, peakCount)
      mapOf(
        "peaks" to peaks,
        "durationMs" to durationMs.toInt(),
      )
    } catch (_: Exception) {
      mapOf(
        "peaks" to List(peakCount) { 0.05 },
        "durationMs" to 0,
      )
    } finally {
      retriever.release()
    }
  }

  fun export(
    context: Context,
    args: Map<*, *>,
    onProgress: (Double) -> Unit,
    onComplete: (Result<String>) -> Unit,
  ) {
    val sourcePath = args["sourcePath"] as? String
    val outputPath = args["outputPath"] as? String
    if (sourcePath == null || outputPath == null) {
      onComplete(Result.failure(IllegalArgumentException("Missing export paths")))
      return
    }
    File(outputPath).delete()
    cancelRequested = false
    activeOutput = File(outputPath)

    val width = (args["width"] as? Number)?.toInt() ?: 1080
    val height = (args["height"] as? Number)?.toInt() ?: 1920
    val rotation = (args["rotationDegrees"] as? Number)?.toFloat() ?: 0f
    val segments = args["segments"] as? List<*> ?: emptyList<Any>()
    val streamCopy = args["streamCopy"] as? Boolean ?: false

    val hasVideoAudio = args["hasVideoAudio"] as? Boolean ?: true
    val overlays = args["overlays"] as? List<*> ?: emptyList<Any>()
    val music = args["music"] as? List<*> ?: emptyList<Any>()
    val composition = buildExportComposition(
      sourcePath = sourcePath,
      width = width,
      height = height,
      rotationDegrees = rotation,
      segments = segments,
      streamCopy = streamCopy,
      hasVideoAudio = hasVideoAudio,
      overlays = overlays,
      music = music,
    )

    val transformer = Transformer.Builder(context)
      .setVideoMimeType(MimeTypes.VIDEO_H264)
      .setAudioMimeType(MimeTypes.AUDIO_AAC)
      .addListener(
        object : Transformer.Listener {
          override fun onCompleted(composition: Composition, result: ExportResult) {
            progressTick?.let { progressHandler?.removeCallbacks(it) }
            if (cancelRequested) {
              File(outputPath).delete()
              onComplete(Result.failure(IllegalStateException("export_cancelled")))
              return
            }
            onProgress(1.0)
            onComplete(Result.success(outputPath))
          }

          override fun onError(
            composition: Composition,
            result: ExportResult,
            exception: ExportException,
          ) {
            progressTick?.let { progressHandler?.removeCallbacks(it) }
            if (cancelRequested) {
              File(outputPath).delete()
              onComplete(Result.failure(IllegalStateException("export_cancelled")))
              return
            }
            onComplete(Result.failure(exception))
          }
        },
      )
      .build()

    // Progress polling — Transformer doesn't expose a continuous callback on all versions.
    val handler = android.os.Handler(Looper.getMainLooper())
    val tick = object : Runnable {
      override fun run() {
        onProgress(0.5)
        handler.postDelayed(this, 250)
      }
    }
    progressHandler = handler
    progressTick = tick
    handler.post(tick)

    activeTransformer = transformer
    transformer.start(composition, outputPath)
    // Stop polling when complete/error via listener above; cancel after a grace.
    handler.postDelayed({ handler.removeCallbacks(tick) }, 120_000)
  }

  private fun buildExportComposition(
    sourcePath: String,
    width: Int,
    height: Int,
    rotationDegrees: Float,
    segments: List<*>,
    streamCopy: Boolean,
    hasVideoAudio: Boolean,
    overlays: List<*>,
    music: List<*>,
  ): Composition {
    val parsed = parseSegments(segments)
    if (streamCopy && parsed.size == 1) {
      val only = parsed.first()
      val item = EditedMediaItem.Builder(
        clipped(sourcePath, only.startMs, only.endMs),
      ).build()
      return Composition.Builder(
        EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)),
      ).build()
    }
    if (parsed.isEmpty()) {
      val item = EditedMediaItem.Builder(
        MediaItem.fromUri(Uri.fromFile(File(sourcePath))),
      ).build()
      return Composition.Builder(
        EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)),
      ).build()
    }

    val plan = packSegments(parsed)
    val videoEffects = videoEffects(width, height, rotationDegrees)
    val sequences = ArrayList<EditedMediaItemSequence>()
    val blends = plan.blends
    if (blends.isEmpty()) {
      val items = parsed.map { seg ->
        EditedMediaItem.Builder(clipped(sourcePath, seg.startMs, seg.endMs))
          .setRemoveAudio(!hasVideoAudio)
          .setEffects(videoEffects)
          .build()
      }
      sequences.add(
        if (hasVideoAudio) {
          EditedMediaItemSequence.withAudioAndVideoFrom(items)
        } else {
          EditedMediaItemSequence.withVideoFrom(items)
        },
      )
    } else {
      sequences.add(videoSequence(sourcePath, plan.tracks[0], plan.totalMs, videoEffects))
      sequences.add(videoSequence(sourcePath, plan.tracks[1], plan.totalMs, videoEffects))
      if (hasVideoAudio) {
        val audioItems = parsed.map { seg ->
          EditedMediaItem.Builder(clipped(sourcePath, seg.startMs, seg.endMs))
            .setRemoveVideo(true)
            .build()
        }
        sequences.add(EditedMediaItemSequence.withAudioFrom(audioItems))
      }
    }
    for (clip in music) {
      val raw = clip as? Map<*, *> ?: continue
      val path = raw["path"] as? String ?: continue
      val timelineMs = (raw["timelineStartMs"] as? Number)?.toLong() ?: 0L
      val offsetMs = (raw["sourceOffsetMs"] as? Number)?.toLong() ?: 0L
      val durationMs = (raw["durationMs"] as? Number)?.toLong() ?: 0L
      val remain = (plan.totalMs - timelineMs).coerceAtLeast(0L)
      val dur = min(durationMs, remain)
      if (dur <= 0L || !File(path).exists()) continue
      val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
      if (timelineMs > 0L) builder.addGap(timelineMs * 1000L)
      builder.addItem(
        EditedMediaItem.Builder(clipped(path, offsetMs, offsetMs + dur))
          .setRemoveVideo(true)
          .build(),
      )
      sequences.add(builder.build())
    }

    Log.i(
      "NativeVideoEngine",
      "export segments=${parsed.size} totalMs=${plan.totalMs} " +
        "blends=${blends.size} overlays=${overlays.size} music=${music.size} " +
        "mode=${if (blends.isEmpty()) "reencode" else "transition"}",
    )
    val builder = Composition.Builder(sequences)
    if (blends.isNotEmpty()) {
      builder.setVideoCompositorSettings(
        TransitionCompositor(width, height, plan.tracks, blends),
      )
    }
    val overlayEffect = overlayEffect(overlays)
    if (overlayEffect != null) {
      builder.setEffects(Effects(emptyList(), listOf(overlayEffect)))
    }
    return builder.build()
  }

  private fun videoEffects(width: Int, height: Int, rotationDegrees: Float): Effects {
    val video = ArrayList<androidx.media3.common.Effect>()
    video.add(
      Presentation.createForWidthAndHeight(
        width,
        height,
        Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP,
      ),
    )
    if (rotationDegrees != 0f) {
      video.add(
        ScaleAndRotateTransformation.Builder()
          .setRotationDegrees(rotationDegrees)
          .build(),
      )
    }
    return Effects(emptyList(), video)
  }

  private fun videoSequence(
    sourcePath: String,
    pieces: List<VideoPiece>,
    totalMs: Long,
    effects: Effects,
  ): EditedMediaItemSequence {
    val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
    var cursor = 0L
    for (piece in pieces) {
      if (piece.compDurMs <= 0L || piece.srcDurMs <= 0L) continue
      if (piece.compStartMs < cursor) continue
      if (piece.compStartMs > cursor) {
        builder.addGap((piece.compStartMs - cursor) * 1000L)
      }
      val speed = piece.srcDurMs.toFloat() / piece.compDurMs.toFloat()
      val item = EditedMediaItem.Builder(
        clipped(sourcePath, piece.srcStartMs, piece.srcStartMs + piece.srcDurMs),
      ).setRemoveAudio(true).setEffects(effects)
      if (abs(speed - 1f) > 0.01f) {
        item.setSpeed(ConstantSpeed(speed))
      }
      builder.addItem(item.build())
      cursor = piece.compStartMs + piece.compDurMs
    }
    if (cursor == 0L) {
      builder.addGap(max(totalMs, 1L) * 1000L)
    } else if (cursor < totalMs) {
      builder.addGap((totalMs - cursor) * 1000L)
    }
    return builder.build()
  }

  private fun clipped(path: String, startMs: Long, endMs: Long): MediaItem {
    return MediaItem.Builder()
      .setUri(Uri.fromFile(File(path)))
      .setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder()
          .setStartPositionMs(startMs)
          .setEndPositionMs(endMs)
          .build(),
      )
      .build()
  }

  private fun overlayEffect(overlays: List<*>): OverlayEffect? {
    val textures = ArrayList<androidx.media3.effect.TextureOverlay>()
    for (raw in overlays) {
      val overlay = raw as? Map<*, *> ?: continue
      val spans = parseSpans(overlay["spans"])
      if (spans.isEmpty()) continue
      textures.add(TimedBitmapOverlay(overlay, spans))
    }
    if (textures.isEmpty()) return null
    return OverlayEffect(textures)
  }

  private fun parseSpans(raw: Any?): List<LongRange> {
    val list = raw as? List<*> ?: return emptyList()
    val spans = ArrayList<LongRange>()
    for (item in list) {
      val span = item as? Map<*, *> ?: continue
      val start = (span["startMs"] as? Number)?.toLong() ?: 0L
      val end = (span["endMs"] as? Number)?.toLong() ?: 0L
      if (end > start) spans.add(start until end)
    }
    return spans
  }

  private fun parseSegments(rawSegments: List<*>): List<ExportSegment> {
    val parsed = ArrayList<ExportSegment>()
    for (raw in rawSegments) {
      val segment = raw as? Map<*, *> ?: continue
      val startMs = (segment["startMs"] as? Number)?.toLong() ?: 0L
      val endMs = (segment["endMs"] as? Number)?.toLong() ?: startMs
      parsed.add(
        ExportSegment(
          startMs = startMs,
          endMs = endMs,
          transitionMs = (segment["transitionDurationMs"] as? Number)?.toLong() ?: 0L,
          effect = (segment["transitionEffect"] as? String)?.lowercase(Locale.US) ?: "fade",
        ),
      )
    }
    return parsed
  }

  /** Same duration-preserving packing as iOS: timeline length is the sum of segment lengths. */
  private fun packSegments(segments: List<ExportSegment>): ExportPlan {
    val tracks = arrayOf(ArrayList<VideoPiece>(), ArrayList<VideoPiece>())
    val blends = ArrayList<BlendWindow>()
    var cursor = 0L
    var prevTd = 0L
    for (index in segments.indices) {
      val seg = segments[index]
      val segDur = (seg.endMs - seg.startMs).coerceAtLeast(0L)
      val track = index % 2
      val td = if (index < segments.lastIndex) seg.transitionMs.coerceAtLeast(0L) else 0L
      val inHalf = transitionHalf(prevTd)
      val outHalf = transitionHalf(td)
      if (prevTd > 0L && inHalf.second > 0L) {
        tracks[track].add(
          VideoPiece(
            compStartMs = cursor - inHalf.first,
            compDurMs = prevTd,
            srcStartMs = seg.startMs,
            srcDurMs = inHalf.second,
          ),
        )
      }
      val soloDur = (segDur - inHalf.second - outHalf.first).coerceAtLeast(0L)
      if (soloDur > 0L) {
        tracks[track].add(
          VideoPiece(
            compStartMs = cursor + inHalf.second,
            compDurMs = soloDur,
            srcStartMs = seg.startMs + inHalf.second,
            srcDurMs = soloDur,
          ),
        )
      }
      if (td > 0L && outHalf.first > 0L) {
        val blendStart = cursor + segDur - outHalf.first
        tracks[track].add(
          VideoPiece(
            compStartMs = blendStart,
            compDurMs = td,
            srcStartMs = seg.endMs - outHalf.first,
            srcDurMs = outHalf.first,
          ),
        )
        blends.add(
          BlendWindow(
            startMs = blendStart,
            durationMs = td,
            effect = seg.effect,
            outgoingTrack = track,
            incomingTrack = (track + 1) % 2,
          ),
        )
      }
      cursor += segDur
      prevTd = td
    }
    tracks[0].sortBy { it.compStartMs }
    tracks[1].sortBy { it.compStartMs }
    return ExportPlan(tracks, blends, cursor)
  }

  private fun transitionHalf(tdMs: Long): Pair<Long, Long> {
    val before = tdMs / 2
    return before to (tdMs - before)
  }
}

private data class ExportSegment(
  val startMs: Long,
  val endMs: Long,
  val transitionMs: Long,
  val effect: String,
)

private data class VideoPiece(
  val compStartMs: Long,
  val compDurMs: Long,
  val srcStartMs: Long,
  val srcDurMs: Long,
)

private data class BlendWindow(
  val startMs: Long,
  val durationMs: Long,
  val effect: String,
  val outgoingTrack: Int,
  val incomingTrack: Int,
)

private data class ExportPlan(
  val tracks: Array<ArrayList<VideoPiece>>,
  val blends: List<BlendWindow>,
  val totalMs: Long,
)

private class ConstantSpeed(private val speed: Float) : SpeedProvider {
  override fun getSpeed(timeUs: Long): Float = speed
  override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
}

@UnstableApi
private class TransitionCompositor(
  private val width: Int,
  private val height: Int,
  private val tracks: Array<ArrayList<VideoPiece>>,
  private val blends: List<BlendWindow>,
) : VideoCompositorSettings {
  override fun getOutputSize(inputSizes: List<Size>): Size = Size(width, height)

  override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
    val ms = presentationTimeUs / 1000L
    val blend = blends.firstOrNull { ms >= it.startMs && ms < it.startMs + it.durationMs }
    if (blend != null && (inputId == blend.outgoingTrack || inputId == blend.incomingTrack)) {
      val t = ((ms - blend.startMs).toFloat() / blend.durationMs.toFloat()).coerceIn(0f, 1f)
      return blendSettings(inputId, blend, t)
    }
    return if (covers(inputId, ms)) opaque() else hidden()
  }

  private fun covers(track: Int, ms: Long): Boolean {
    val pieces = tracks.getOrNull(track) ?: return false
    return pieces.any { ms >= it.compStartMs && ms < it.compStartMs + it.compDurMs }
  }

  private fun blendSettings(inputId: Int, blend: BlendWindow, t: Float): OverlaySettings {
    return when (blend.effect) {
      "slideleft", "pushleft" ->
        shift(if (inputId == blend.outgoingTrack) -t else 1f - t, 0f)
      "slideright", "pushright" ->
        shift(if (inputId == blend.outgoingTrack) t else -(1f - t), 0f)
      "slideup", "pushup" ->
        shift(0f, if (inputId == blend.outgoingTrack) t else -(1f - t))
      "slidedown", "pushdown" ->
        shift(0f, if (inputId == blend.outgoingTrack) -t else 1f - t)
      "coverleft" -> cover(inputId, blend, axisX = true, incomingFrom = 1f, t = t)
      "coverright" -> cover(inputId, blend, axisX = true, incomingFrom = -1f, t = t)
      "coverup" -> cover(inputId, blend, axisX = false, incomingFrom = -1f, t = t)
      "coverdown" -> cover(inputId, blend, axisX = false, incomingFrom = 1f, t = t)
      else -> fade(inputId, blend, t)
    }
  }

  private fun cover(
    inputId: Int,
    blend: BlendWindow,
    axisX: Boolean,
    incomingFrom: Float,
    t: Float,
  ): OverlaySettings {
    val incomingOnTop = blend.incomingTrack == 0
    if (incomingOnTop) {
      if (inputId != blend.incomingTrack) return opaque()
      val delta = incomingFrom * (1f - t)
      return if (axisX) shift(delta, 0f) else shift(0f, delta)
    }
    if (inputId != blend.outgoingTrack) return opaque()
    val delta = -incomingFrom * t
    return if (axisX) shift(delta, 0f) else shift(0f, delta)
  }

  private fun fade(inputId: Int, blend: BlendWindow, t: Float): OverlaySettings {
    val outgoingOnTop = blend.outgoingTrack == 0
    val alpha = if (inputId == blend.outgoingTrack) {
      if (outgoingOnTop) 1f - t else 1f
    } else if (outgoingOnTop) {
      1f
    } else {
      t
    }
    return StaticOverlaySettings.Builder().setAlphaScale(alpha).build()
  }

  private fun shift(x: Float, y: Float): OverlaySettings {
    val cx = x.coerceIn(-1f, 1f)
    val cy = y.coerceIn(-1f, 1f)
    if (cx == 0f && cy == 0f) return opaque()
    return StaticOverlaySettings.Builder()
      .setAlphaScale(1f)
      .setOverlayFrameAnchor(-cx, -cy)
      .setBackgroundFrameAnchor(cx, cy)
      .build()
  }

  private fun opaque(): OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(1f).build()

  private fun hidden(): OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(0f).build()
}

@UnstableApi
private class TimedBitmapOverlay(
  private val overlay: Map<*, *>,
  private val spans: List<LongRange>,
) : BitmapOverlay() {
  private val cache = HashMap<String, Bitmap>()

  override fun getBitmap(presentationTimeUs: Long): Bitmap {
    val path = imagePath(presentationTimeUs / 1000L) ?: return emptyBitmap
    synchronized(cache) {
      cache[path]?.let { if (!it.isRecycled) return it }
      val decoded = BitmapFactory.decodeFile(path) ?: return emptyBitmap
      cache[path] = decoded
      return decoded
    }
  }

  override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
    val ms = presentationTimeUs / 1000L
    val on = spans.any { ms in it }
    return StaticOverlaySettings.Builder().setAlphaScale(if (on) 1f else 0f).build()
  }

  private fun imagePath(timeMs: Long): String? {
    val file = overlay["path"] as? String
    if (file != null) return file
    val dir = overlay["sequenceDir"] as? String ?: return null
    val count = (overlay["frameCount"] as? Number)?.toInt() ?: return null
    if (count <= 0) return null
    val rate = (overlay["frameRate"] as? Number)?.toDouble() ?: 30.0
    if (spans.isEmpty()) return null
    // A transition splits one overlay into a span per clip. Clock from the
    // first span so the entrance does not play again at the cut.
    val anchor = spans.minOf { it.first }
    val index = ((timeMs - anchor) * rate / 1000.0).toInt().coerceIn(0, count - 1)
    return String.format(Locale.US, "%s/frame_%04d.png", dir, index + 1)
  }

  companion object {
    private val emptyBitmap: Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
  }
}

@UnstableApi
private object WaveformDecoder {
  fun decodePeaks(path: String, peakCount: Int): List<Double> {
    // Prefer scanning a short PCM dump if MediaExtractor yields audio; otherwise flat.
    return try {
      val extractor = android.media.MediaExtractor()
      extractor.setDataSource(path)
      var track = -1
      var format: MediaFormat? = null
      for (i in 0 until extractor.trackCount) {
        val f = extractor.getTrackFormat(i)
        val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
        if (MimeTypes.isAudio(mime)) {
          track = i
          format = f
          break
        }
      }
      if (track < 0 || format == null) {
        extractor.release()
        return List(peakCount) { 0.08 }
      }
      extractor.selectTrack(track)
      val mime = format.getString(MediaFormat.KEY_MIME)!!
      val codec = android.media.MediaCodec.createDecoderByType(mime)
      codec.configure(format, null, null, 0)
      codec.start()

      val samples = ArrayList<Short>(64_000)
      val info = android.media.MediaCodec.BufferInfo()
      var inputDone = false
      var safety = 0
      while (safety++ < 400 && samples.size < 250_000) {
        if (!inputDone) {
          val inIndex = codec.dequeueInputBuffer(5_000)
          if (inIndex >= 0) {
            val buf = codec.getInputBuffer(inIndex)!!
            val size = extractor.readSampleData(buf, 0)
            if (size < 0) {
              codec.queueInputBuffer(inIndex, 0, 0, 0, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }
        val outIndex = codec.dequeueOutputBuffer(info, 5_000)
        if (outIndex >= 0) {
          val out = codec.getOutputBuffer(outIndex)!!
          out.order(ByteOrder.LITTLE_ENDIAN)
          while (out.remaining() >= 2 && samples.size < 250_000) {
            samples.add(out.short)
          }
          codec.releaseOutputBuffer(outIndex, false)
          if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
        }
      }
      codec.stop()
      codec.release()
      extractor.release()

      if (samples.isEmpty()) return List(peakCount) { 0.08 }
      val bucket = max(1, samples.size / peakCount)
      val peaks = DoubleArray(peakCount)
      var tallest = 0.0
      for (i in 0 until peakCount) {
        val start = i * bucket
        if (start >= samples.size) break
        val end = min(start + bucket, samples.size)
        var maxAbs = 0
        for (s in start until end) {
          maxAbs = max(maxAbs, abs(samples[s].toInt()))
        }
        val v = (maxAbs / 32768.0).coerceIn(0.0, 1.0)
        peaks[i] = v
        tallest = max(tallest, v)
      }
      if (tallest > 0.05) {
        for (i in peaks.indices) peaks[i] = (peaks[i] / tallest).coerceIn(0.0, 1.0)
      }
      peaks.toList()
    } catch (_: Exception) {
      List(peakCount) { 0.08 }
    }
  }
}
