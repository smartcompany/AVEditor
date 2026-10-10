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
import kotlin.math.roundToInt

/** Shared export composition played by the timeline and written by album export. */
internal data class TimelinePreview(
  val composition: Composition,
  val width: Int,
  val height: Int,
  val durationMs: Int,
  /** Live blend list the timeline mixer reads every frame. Export leaves this null. */
  val mix: TimelineMix? = null,
)

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

  /** Same composition the timeline player prepares. Tests call this without a device file probe. */
  internal fun buildCompositionForTest(
    sourcePath: String,
    segments: List<*>,
    hasVideoAudio: Boolean,
    forPlayback: Boolean,
    width: Int = 404,
    height: Int = 720,
  ): Composition {
    return buildExportComposition(
      sourcePath = sourcePath,
      width = width,
      height = height,
      rotationDegrees = 0f,
      segments = segments,
      streamCopy = false,
      hasVideoAudio = hasVideoAudio,
      overlays = emptyList<Any>(),
      music = emptyList<Any>(),
      forPlayback = forPlayback,
    )
  }

  /**
   * Preview composition. One [androidx.media3.transformer.CompositionPlayer] plays one
   * video sequence. A transition is drawn in the frame effect from that frame plus the
   * incoming picture.
   */
  internal fun buildTimelinePreview(
    sourcePath: String,
    segments: List<*>,
    mix: TimelineMix? = null,
  ): TimelinePreview {
    val retriever = MediaMetadataRetriever()
    val oriented = try {
      retriever.setDataSource(sourcePath)
      var width =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
          ?: 720
      var height =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
          ?: 1280
      val rotation =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
          ?: 0
      if (rotation == 90 || rotation == 270) {
        val swap = width
        width = height
        height = swap
      }
      val hasAudio =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
      Triple(max(1, width), max(1, height), hasAudio)
    } finally {
      retriever.release()
    }
    val longSide = max(oriented.first, oriented.second).coerceAtLeast(1)
    val fit = min(1.0, 720.0 / longSide)
    val outW = max(2, (kotlin.math.floor(oriented.first * fit / 2.0) * 2.0).toInt())
    val outH = max(2, (kotlin.math.floor(oriented.second * fit / 2.0) * 2.0).toInt())
    val liveMix = mix ?: TimelineMix()
    val composition = buildExportComposition(
      sourcePath = sourcePath,
      width = outW,
      height = outH,
      rotationDegrees = 0f,
      segments = segments,
      streamCopy = false,
      hasVideoAudio = oriented.third,
      overlays = emptyList<Any>(),
      music = emptyList<Any>(),
      forPlayback = true,
      mix = liveMix,
    )
    var durationMs = 0L
    for (raw in segments) {
      val segment = raw as? Map<*, *> ?: continue
      val startMs = (segment["startMs"] as? Number)?.toLong() ?: 0L
      val endMs = (segment["endMs"] as? Number)?.toLong() ?: startMs
      durationMs += (endMs - startMs).coerceAtLeast(0L)
    }
    Log.i(
      "NativeVideoEngine",
      "timeline preview ${outW}x$outH durationMs=$durationMs segments=${segments.size}",
    )
    return TimelinePreview(
      composition,
      outW,
      outH,
      durationMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
      liveMix,
    )
  }

  /** Clips played when the preview has no transition. */
  private fun previewPlan(segments: List<*>): ExportPlan {
    val clips = coalesceHardCuts(parseSegments(segments))
    val pieces = ArrayList<VideoPiece>()
    var cursor = 0L
    for (seg in clips) {
      val dur = (seg.endMs - seg.startMs).coerceAtLeast(0L)
      pieces.add(VideoPiece(cursor, dur, seg.startMs, dur))
      cursor += dur
    }
    return ExportPlan(arrayOf(pieces, ArrayList()), emptyList(), cursor)
  }

  internal fun sameMixerLayout(mix: TimelineMix, segments: List<*>): Boolean {
    return mix.matchesPlayback(playbackLayout(segments))
  }

  /** One sequence. Through a blend the player keeps showing the outgoing clip. */
  private fun playbackLayout(segments: List<*>): ExportPlan {
    val packed = packSegments(parseSegments(segments))
    if (packed.blends.isEmpty()) return previewPlan(segments)
    return ExportPlan(
      arrayOf(playbackPieces(packed), ArrayList()),
      emptyList(),
      packed.totalMs,
    )
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
    forPlayback: Boolean = false,
    mix: TimelineMix? = null,
  ): Composition {
    val parsed = parseSegments(segments)
    if (streamCopy && parsed.size == 1) {
      val only = parsed.first()
      val item = clipItem(sourcePath, only.startMs, only.endMs)
      return Composition.Builder(
        EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)),
      ).build()
    }
    if (parsed.isEmpty()) {
      val durationMs = (probe(sourcePath)["durationMs"] as? Int)?.toLong() ?: 0L
      val item = EditedMediaItem.Builder(
        MediaItem.fromUri(Uri.fromFile(File(sourcePath))),
      ).setDurationUs(max(durationMs, 1L) * 1000L).build()
      return Composition.Builder(
        EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)),
      ).build()
    }

    val plan = packSegments(parsed)
    val playbackBlend = forPlayback && plan.blends.isNotEmpty()
    val played = if (playbackBlend) playbackPieces(plan) else ArrayList()
    val drawPlan = if (playbackBlend) {
      ExportPlan(arrayOf(played, ArrayList<VideoPiece>()), plan.blends, plan.totalMs)
    } else {
      plan
    }
    val videoEffects = videoEffects(width, height, rotationDegrees)
    val sequences = ArrayList<EditedMediaItemSequence>()
    val blends = plan.blends
    if (forPlayback && mix != null) {
      mix.sourcePath = if (playbackBlend) sourcePath else ""
      mix.setPlayback(playbackLayout(segments))
      mix.set(
        if (playbackBlend) {
          plan
        } else {
          ExportPlan(arrayOf(ArrayList(), ArrayList()), emptyList(), plan.totalMs)
        },
      )
    }
    val holder = if (blends.isEmpty()) {
      null
    } else if (forPlayback && mix != null) {
      mix
    } else {
      (mix ?: TimelineMix()).also {
        it.sourcePath = ""
        it.set(plan)
      }
    }
    if (forPlayback || blends.isEmpty()) {
      if (playbackBlend) {
        sequences.add(
          playbackSequence(
            sourcePath,
            played,
            plan.totalMs,
            videoEffects,
            removeAudio = !hasVideoAudio,
          ),
        )
      } else {
        // A split is a marker. Separate clipped items make the export join at a
        // boundary that does not exist in the source.
        val items = coalesceHardCuts(parsed).map { seg ->
          clipItem(
            sourcePath,
            seg.startMs,
            seg.endMs,
            removeAudio = !hasVideoAudio,
            effects = videoEffects,
          )
        }
        sequences.add(
          if (hasVideoAudio) {
            EditedMediaItemSequence.withAudioAndVideoFrom(items)
          } else {
            EditedMediaItemSequence.withVideoFrom(items)
          },
        )
      }
    } else {
      sequences.add(videoSequence(sourcePath, plan.tracks[0], plan.totalMs, videoEffects))
      sequences.add(videoSequence(sourcePath, plan.tracks[1], plan.totalMs, videoEffects))
      if (hasVideoAudio) {
        val audioItems = parsed.map { seg ->
          clipItem(sourcePath, seg.startMs, seg.endMs, removeVideo = true)
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
        clipItem(path, offsetMs, offsetMs + dur, removeVideo = true),
      )
      sequences.add(builder.build())
    }

    Log.i(
      "NativeVideoEngine",
      "compose segments=${parsed.size} totalMs=${plan.totalMs} " +
        "blends=${blends.size} overlays=${overlays.size} music=${music.size} " +
        "mode=${when {
          forPlayback -> "playback"
          blends.isEmpty() -> "reencode"
          else -> "transition"
        }} " +
        "size=${width}x$height",
    )
    for (index in parsed.indices) {
      val seg = parsed[index]
      Log.i(
        "NativeVideoEngine",
        "compose segment#$index ${seg.startMs}-${seg.endMs} " +
          "td=${seg.transitionMs} effect=${seg.effect} kind=${seg.kind} " +
          "layers=${seg.layers.size}",
      )
    }
    for (index in blends.indices) {
      val blend = blends[index]
      Log.i(
        "NativeVideoEngine",
        "compose blend#$index start=${blend.startMs} dur=${blend.durationMs} " +
          "effect=${blend.effect} kind=${blend.kind} " +
          "out=${blend.outgoingTrack} in=${blend.incomingTrack}",
      )
    }
    for (track in drawPlan.tracks.indices) {
      for (piece in drawPlan.tracks[track]) {
        val speed = piece.srcDurMs.toFloat() / piece.compDurMs.toFloat()
        Log.i(
          "NativeVideoEngine",
          "compose track$track comp=${piece.compStartMs}+${piece.compDurMs} " +
            "src=${piece.srcStartMs}+${piece.srcDurMs} speed=$speed " +
            "hidden=${piece.hidden}",
        )
      }
    }
    val builder = Composition.Builder(sequences)
    if (holder != null && !forPlayback) {
      builder.setVideoCompositorSettings(TransitionCompositor(width, height, holder))
    }
    val compositionEffects = ArrayList<androidx.media3.common.Effect>()
    if (holder != null) {
      compositionEffects.add(TransitionBlendEffect(holder))
    }
    val overlayEffect = overlayEffect(overlays)
    if (overlayEffect != null) compositionEffects.add(overlayEffect)
    if (compositionEffects.isNotEmpty()) {
      builder.setEffects(Effects(emptyList(), compositionEffects))
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
    removeAudio: Boolean = true,
    idSuffix: String = "",
  ): EditedMediaItemSequence {
    val types = if (removeAudio) {
      setOf(C.TRACK_TYPE_VIDEO)
    } else {
      setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)
    }
    val builder = EditedMediaItemSequence.Builder(types)
    var cursor = 0L
    for (piece in pieces) {
      if (piece.compDurMs <= 0L || piece.srcDurMs <= 0L) continue
      if (piece.compStartMs < cursor) continue
      if (piece.compStartMs > cursor) {
        builder.addGap((piece.compStartMs - cursor) * 1000L)
      }
      val speed = piece.srcDurMs.toFloat() / piece.compDurMs.toFloat()
      val item = clipItem(
        sourcePath,
        piece.srcStartMs,
        piece.srcStartMs + piece.srcDurMs,
        removeAudio = removeAudio,
        effects = effects,
        speed = speed,
        idSuffix = "$idSuffix@${piece.compStartMs}",
      )
      builder.addItem(item)
      cursor = piece.compStartMs + piece.compDurMs
    }
    if (cursor == 0L) {
      builder.addGap(max(totalMs, 1L) * 1000L)
    } else if (cursor < totalMs) {
      builder.addGap((totalMs - cursor) * 1000L)
    }
    return builder.build()
  }

  /**
   * One media item for the whole preview. A new item at the end of a blend
   * releases the decoder and the next period stays buffering.
   */
  private fun playbackSequence(
    sourcePath: String,
    pieces: List<VideoPiece>,
    totalMs: Long,
    effects: Effects,
    removeAudio: Boolean,
  ): EditedMediaItemSequence {
    val types = if (removeAudio) {
      setOf(C.TRACK_TYPE_VIDEO)
    } else {
      setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)
    }
    val builder = EditedMediaItemSequence.Builder(types)
    var cursor = 0L
    var index = 0
    while (index < pieces.size) {
      val first = pieces[index]
      if (first.compDurMs <= 0L || first.srcDurMs <= 0L) {
        index++
        continue
      }
      if (first.compStartMs > cursor) {
        builder.addGap((first.compStartMs - cursor) * 1000L)
      }
      var srcEnd = first.srcStartMs + first.srcDurMs
      var compEnd = first.compStartMs + first.compDurMs
      val changes = ArrayList<Pair<Long, Float>>()
      var inputUs = 0L
      changes.add(inputUs to pieceSpeed(first))
      inputUs += first.srcDurMs * 1000L
      var next = index + 1
      while (next < pieces.size) {
        val piece = pieces[next]
        if (piece.compStartMs != compEnd) break
        if (piece.srcStartMs > srcEnd) {
          val gapUs = (piece.srcStartMs - srcEnd) * 1000L
          changes.add(inputUs to gapUs * 2f)
          inputUs += gapUs
          srcEnd = piece.srcStartMs
        } else if (piece.srcStartMs != srcEnd) {
          break
        }
        val speed = pieceSpeed(piece)
        if (abs(speed - changes.last().second) > 0.01f) {
          changes.add(inputUs to speed)
        }
        inputUs += piece.srcDurMs * 1000L
        srcEnd = piece.srcStartMs + piece.srcDurMs
        compEnd = piece.compStartMs + piece.compDurMs
        next++
      }
      val provider = if (changes.size == 1 && abs(changes[0].second - 1f) <= 0.01f) {
        null
      } else {
        PiecewiseSpeed(changes)
      }
      builder.addItem(
        clipItem(
          sourcePath,
          first.srcStartMs,
          srcEnd,
          removeAudio = removeAudio,
          effects = effects,
          speedProvider = provider,
          idSuffix = "@${first.compStartMs}",
        ),
      )
      cursor = compEnd
      index = next
    }
    if (cursor == 0L) {
      builder.addGap(max(totalMs, 1L) * 1000L)
    } else if (cursor < totalMs) {
      builder.addGap((totalMs - cursor) * 1000L)
    }
    return builder.build()
  }

  private fun pieceSpeed(piece: VideoPiece): Float {
    return piece.srcDurMs.toFloat() / piece.compDurMs.toFloat()
  }

  /**
   * CompositionPlayer rejects an item whose durationUs is unset, so a timeline
   * that contains a transition never starts and the preview falls back to a hard cut.
   * durationUs is the source end; clipping and [ConstantSpeed] then yield the
   * composition length.
   */
  private fun clipItem(
    path: String,
    startMs: Long,
    endMs: Long,
    removeAudio: Boolean = false,
    removeVideo: Boolean = false,
    effects: Effects? = null,
    speed: Float = 1f,
    speedProvider: SpeedProvider? = null,
    idSuffix: String = "",
  ): EditedMediaItem {
    val end = endMs.coerceAtLeast(startMs + 1L)
    val item = EditedMediaItem.Builder(clipped(path, startMs, end, idSuffix))
      .setRemoveAudio(removeAudio)
      .setRemoveVideo(removeVideo)
      .setDurationUs(end * 1000L)
    if (effects != null) item.setEffects(effects)
    when {
      speedProvider != null -> item.setSpeed(speedProvider)
      abs(speed - 1f) > 0.01f -> item.setSpeed(ConstantSpeed(speed))
    }
    return item.build()
  }

  private fun clipped(path: String, startMs: Long, endMs: Long, idSuffix: String = ""): MediaItem {
    return MediaItem.Builder()
      .setUri(Uri.fromFile(File(path)))
      .setMediaId("clip-$startMs-$endMs$idSuffix")
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

  private fun parseSpans(raw: Any?): List<OverlaySpan> {
    val list = raw as? List<*> ?: return emptyList()
    val spans = ArrayList<OverlaySpan>()
    for (item in list) {
      val span = item as? Map<*, *> ?: continue
      val start = (span["startMs"] as? Number)?.toLong() ?: 0L
      val end = (span["endMs"] as? Number)?.toLong() ?: 0L
      if (end <= start) continue
      val sourceStart = (span["sourceStartMs"] as? Number)?.toLong() ?: start
      spans.add(OverlaySpan(start, end, sourceStart))
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
          layers = parseMotionLayers(segment["transitionLayers"]),
          kind = (segment["transitionKind"] as? String)?.lowercase(Locale.US) ?: "",
          reverse = segment["transitionReverse"] as? Boolean ?: false,
          edge = ((segment["transitionParams"] as? Map<*, *>)?.get("edge") as? String)
            ?.lowercase(Locale.US) ?: "",
          scaleFrom = ((segment["transitionParams"] as? Map<*, *>)?.get("incomingScaleFrom") as? Number)
            ?.toFloat() ?: 0.84f,
          scaleTo = ((segment["transitionParams"] as? Map<*, *>)?.get("incomingScaleTo") as? Number)
            ?.toFloat() ?: 1f,
        ),
      )
    }
    return parsed
  }

  /**
   * Adjacent hard cuts are one source range. A split does not remove frames,
   * and a new item at the cut is where playback stops.
   */
  private fun coalesceHardCuts(segments: List<ExportSegment>): List<ExportSegment> {
    if (segments.isEmpty()) return segments
    val merged = ArrayList<ExportSegment>()
    var current = segments.first()
    for (index in 1 until segments.size) {
      val next = segments[index]
      if (current.transitionMs <= 0L && current.endMs == next.startMs) {
        current = current.copy(
          endMs = next.endMs,
          transitionMs = next.transitionMs,
          effect = next.effect,
          layers = next.layers,
          kind = next.kind,
          reverse = next.reverse,
          edge = next.edge,
          scaleFrom = next.scaleFrom,
          scaleTo = next.scaleTo,
        )
      } else {
        merged.add(current)
        current = next
      }
    }
    merged.add(current)
    return merged
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
            layers = seg.layers,
            kind = seg.kind,
            reverse = seg.reverse,
            edge = seg.edge,
            scaleFrom = seg.scaleFrom,
            scaleTo = seg.scaleTo,
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

  /**
   * Playback stays one sequence, so the player does not wait for a second clip
   * at the blend. The outgoing picture stays on screen through the blend.
   */
  private fun playbackPieces(plan: ExportPlan): ArrayList<VideoPiece> {
    val out = ArrayList<VideoPiece>()
    var cursor = 0L
    while (cursor < plan.totalMs) {
      val blend = plan.blends.firstOrNull { cursor < it.startMs + it.durationMs }
      val active = blend?.takeIf { cursor >= it.startMs }
      val limit = when {
        active != null -> active.startMs + active.durationMs
        blend != null -> blend.startMs
        else -> plan.totalMs
      }
      val track = if (active != null) active.outgoingTrack else trackCovering(plan, cursor)
      if (track < 0) break
      val piece = plan.tracks[track].firstOrNull {
        !it.hidden && cursor >= it.compStartMs && cursor < it.compStartMs + it.compDurMs
      } ?: break
      val end = min(limit, piece.compStartMs + piece.compDurMs)
      val sliced = slicePiece(piece, cursor, end) ?: break
      out.add(sliced)
      cursor = end
    }
    return out
  }

  private fun trackCovering(plan: ExportPlan, cursor: Long): Int {
    for (track in plan.tracks.indices) {
      val hit = plan.tracks[track].any {
        !it.hidden && cursor >= it.compStartMs && cursor < it.compStartMs + it.compDurMs
      }
      if (hit) return track
    }
    return -1
  }

  private fun slicePiece(piece: VideoPiece, from: Long, to: Long): VideoPiece? {
    val compDur = to - from
    if (compDur <= 0L || piece.compDurMs <= 0L) return null
    val srcOffset = (from - piece.compStartMs) * piece.srcDurMs / piece.compDurMs
    val srcDur = compDur * piece.srcDurMs / piece.compDurMs
    if (srcDur <= 0L) return null
    return piece.copy(
      compStartMs = from,
      compDurMs = compDur,
      srcStartMs = piece.srcStartMs + srcOffset,
      srcDurMs = srcDur,
    )
  }

  /**
   * CompositionPlayer waits for a frame from every input. A gap produces none,
   * so a transition project stays BUFFERING at position 0. Copy the other
   * track into that gap and mark it hidden — the compositor draws alpha 0,
   * but the decoder still releases buffers.
   */
  private fun fillDecoderGaps(plan: ExportPlan): ExportPlan {
    val filled = arrayOf(
      fillGaps(plan.tracks[0], plan.tracks[1], plan.totalMs),
      fillGaps(plan.tracks[1], plan.tracks[0], plan.totalMs),
    )
    return ExportPlan(filled, plan.blends, plan.totalMs)
  }

  private fun fillGaps(
    mine: List<VideoPiece>,
    other: List<VideoPiece>,
    totalMs: Long,
  ): ArrayList<VideoPiece> {
    val visible = mine.filter { !it.hidden }.sortedBy { it.compStartMs }
    val donors = other.filter { !it.hidden }.sortedBy { it.compStartMs }
    val out = ArrayList<VideoPiece>()
    var cursor = 0L
    for (piece in visible) {
      if (piece.compStartMs > cursor) {
        out.addAll(hiddenCovering(donors, cursor, piece.compStartMs))
      }
      out.add(piece)
      cursor = max(cursor, piece.compStartMs + piece.compDurMs)
    }
    if (cursor < totalMs) {
      out.addAll(hiddenCovering(donors, cursor, totalMs))
    }
    return out
  }

  private fun hiddenCovering(
    donors: List<VideoPiece>,
    from: Long,
    to: Long,
  ): List<VideoPiece> {
    val result = ArrayList<VideoPiece>()
    var cursor = from
    while (cursor < to) {
      val donor = donors.firstOrNull { piece ->
        cursor >= piece.compStartMs && cursor < piece.compStartMs + piece.compDurMs
      } ?: break
      val gapEnd = min(to, donor.compStartMs + donor.compDurMs)
      val compDur = gapEnd - cursor
      if (compDur <= 0L || donor.compDurMs <= 0L) break
      val srcDur = compDur * donor.srcDurMs / donor.compDurMs
      val srcOffset = (cursor - donor.compStartMs) * donor.srcDurMs / donor.compDurMs
      if (srcDur > 0L) {
        result.add(
          VideoPiece(
            compStartMs = cursor,
            compDurMs = compDur,
            srcStartMs = donor.srcStartMs + srcOffset,
            srcDurMs = srcDur,
            hidden = true,
          ),
        )
      }
      cursor = gapEnd
    }
    return result
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
  val layers: List<MotionLayer> = emptyList(),
  val kind: String = "",
  val reverse: Boolean = false,
  val edge: String = "",
  val scaleFrom: Float = 0.84f,
  val scaleTo: Float = 1f,
)

internal data class VideoPiece(
  val compStartMs: Long,
  val compDurMs: Long,
  val srcStartMs: Long,
  val srcDurMs: Long,
  val hidden: Boolean = false,
)

internal data class BlendWindow(
  val startMs: Long,
  val durationMs: Long,
  val effect: String,
  val outgoingTrack: Int,
  val incomingTrack: Int,
  val layers: List<MotionLayer> = emptyList(),
  val kind: String = "",
  val reverse: Boolean = false,
  val edge: String = "",
  val scaleFrom: Float = 0.84f,
  val scaleTo: Float = 1f,
)

internal data class MotionLayer(
  val property: String,
  val from: Float,
  val to: Float,
  val easing: String,
  val target: String,
  val start: Float,
  val end: Float,
  val mode: String = "",
  val columns: Int = 0,
  val rows: Int = 0,
  val gap: Float = 0f,
  val stagger: Float = 0f,
)

internal data class MotionPose(
  var opacity: Float = 1f,
  var scale: Float = 1f,
  var turns: Float = 0f,
  var tx: Float = 0f,
  var ty: Float = 0f,
  var blur: Float = 0f,
  var blurMode: String = "",
  var brightness: Float = 0f,
  var wipe: Float = 0f,
  var wipeEdge: String = "left",
  var ripple: Float = 0f,
  var rotationY: Float = 0f,
)

private fun parseMotionLayers(raw: Any?): List<MotionLayer> {
  val list = raw as? List<*> ?: return emptyList()
  val layers = ArrayList<MotionLayer>()
  for (item in list) {
    val map = item as? Map<*, *> ?: continue
    val property = map["property"] as? String ?: continue
    val start = (map["start"] as? Number)?.toFloat() ?: 0f
    val end = (map["end"] as? Number)?.toFloat() ?: 1f
    layers.add(
      MotionLayer(
        property = property,
        from = (map["from"] as? Number)?.toFloat() ?: 0f,
        to = (map["to"] as? Number)?.toFloat() ?: 0f,
        easing = map["easing"] as? String ?: "linear",
        target = map["target"] as? String ?: "A",
        start = start,
        end = max(start, end),
        mode = (map["mode"] as? String)?.lowercase(Locale.US) ?: "",
        columns = ((map["grid"] as? Map<*, *>)?.get("columns") as? Number)?.toInt() ?: 0,
        rows = ((map["grid"] as? Map<*, *>)?.get("rows") as? Number)?.toInt() ?: 0,
        gap = ((map["grid"] as? Map<*, *>)?.get("gap") as? Number)?.toFloat() ?: 0f,
        stagger = ((map["grid"] as? Map<*, *>)?.get("stagger") as? Number)?.toFloat() ?: 0f,
      ),
    )
  }
  return layers
}

internal fun motionEase(t: Float, name: String): Float {
  val u = t.coerceIn(0f, 1f)
  return when (name) {
    "easeOut" -> 1f - (1f - u) * (1f - u) * (1f - u)
    "easeIn" -> u * u * u
    "easeInOut" ->
      if (u < 0.5f) 4f * u * u * u
      else {
        val v = -2f * u + 2f
        1f - (v * v * v) / 2f
      }
    else -> u
  }
}

/** Same pose evaluation as iOS [evaluateExportPoses], for fields OverlaySettings can draw. */
internal fun motionOutgoingOnTop(layers: List<MotionLayer>): Boolean {
  var top: String? = null
  for (layer in layers) {
    if (layer.target == "A" || layer.target == "B") top = layer.target
  }
  return top == "A"
}

internal fun evaluateMotionPoses(layers: List<MotionLayer>, t: Float): Pair<MotionPose, MotionPose> {
  val outgoing = MotionPose()
  val incoming = MotionPose(opacity = 0f)
  val hasOpacity = layers.any { it.property == "opacity" }
  if (!hasOpacity) {
    val spatial = layers.any {
      it.property == "translateX" || it.property == "translateY" ||
        it.property == "rotation" || it.property == "rotationY" ||
        it.property == "ripple" || it.property == "wipe"
    }
    if (spatial) {
      outgoing.opacity = 1f
      incoming.opacity = 1f
    } else {
      outgoing.opacity = 1f - t
      incoming.opacity = t
    }
  }
  var outgoingOpacity = false
  var incomingOpacity = false
  for (layer in layers) {
    if (t < layer.start) continue
    val span = max(layer.end - layer.start, 0.0001f)
    val local = ((t - layer.start) / span).coerceIn(0f, 1f)
    val value = layer.from + (layer.to - layer.from) * motionEase(local, layer.easing)
    fun apply(pose: MotionPose, markOpacity: Boolean): Boolean {
      when (layer.property) {
        "opacity" -> {
          pose.opacity = value.coerceIn(0f, 1f)
          return true
        }
        "scale" -> pose.scale = value
        "rotation" -> pose.turns = value
        "translateX" -> pose.tx = value
        "translateY" -> pose.ty = value
        "blur" -> {
          pose.blur = value
          if (layer.mode.isNotEmpty()) pose.blurMode = layer.mode
        }
        "brightness" -> pose.brightness = value
        "wipe" -> {
          pose.wipe = value.coerceIn(0f, 1f)
          if (layer.mode.isNotEmpty()) pose.wipeEdge = layer.mode
        }
        "ripple" -> pose.ripple = value.coerceIn(0f, 1f)
        "rotationY" -> pose.rotationY = value
      }
      return markOpacity
    }
    if (layer.target == "A" || layer.target == "both") {
      outgoingOpacity = apply(outgoing, outgoingOpacity)
    }
    if (layer.target == "B" || layer.target == "both") {
      incomingOpacity = apply(incoming, incomingOpacity)
    }
  }
  if (hasOpacity) {
    if (outgoingOpacity && !incomingOpacity) incoming.opacity = 1f - outgoing.opacity
    if (incomingOpacity && !outgoingOpacity) outgoing.opacity = 1f - incoming.opacity
  }
  return outgoing to incoming
}

private fun motionLayersDrawable(layers: List<MotionLayer>): Boolean {
  return layers.any {
    it.property == "opacity" || it.property == "scale" || it.property == "rotation" ||
      it.property == "translateX" || it.property == "translateY"
  }
}

internal data class ExportPlan(
  val tracks: Array<ArrayList<VideoPiece>>,
  val blends: List<BlendWindow>,
  val totalMs: Long,
)

private class ConstantSpeed(private val speed: Float) : SpeedProvider {
  override fun getSpeed(timeUs: Long): Float = speed
  override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
}

private class PiecewiseSpeed(
  private val changes: List<Pair<Long, Float>>,
) : SpeedProvider {
  override fun getSpeed(timeUs: Long): Float {
    var speed = changes.first().second
    for ((at, value) in changes) {
      if (at > timeUs) break
      speed = value
    }
    return speed
  }

  override fun getNextSpeedChangeTimeUs(timeUs: Long): Long {
    for ((at, _) in changes) {
      if (at > timeUs) return at
    }
    return C.TIME_UNSET
  }
}

/**
 * Blend windows the timeline mixer reads on every frame.
 * Applying a transition replaces this list. The player stays open.
 */
internal class TimelineMix {
  val blends = ArrayList<BlendWindow>()
  val tracks = arrayOf(ArrayList<VideoPiece>(), ArrayList<VideoPiece>())
  var sourcePath: String = ""
  /** Called on the GL thread after the output frame for [ms] is drawn. */
  @Volatile var onDrawnMs: ((Long) -> Unit)? = null
  private val playback = arrayOf(ArrayList<VideoPiece>(), ArrayList<VideoPiece>())

  fun set(plan: ExportPlan) {
    blends.clear()
    blends.addAll(plan.blends)
    tracks[0].clear()
    tracks[0].addAll(plan.tracks[0])
    tracks[1].clear()
    tracks[1].addAll(plan.tracks[1])
  }

  fun setPlayback(plan: ExportPlan) {
    playback[0].clear()
    playback[0].addAll(plan.tracks[0])
    playback[1].clear()
    playback[1].addAll(plan.tracks[1])
  }

  /** Source time of the incoming clip at [compMs], in microseconds. */
  fun incomingSourceUs(compMs: Long): Long {
    val blend = blends.firstOrNull { compMs >= it.startMs && compMs < it.startMs + it.durationMs }
      ?: return compMs * 1000L
    val pieces = tracks.getOrNull(blend.incomingTrack) ?: return compMs * 1000L
    val piece = pieces.firstOrNull {
      !it.hidden && compMs >= it.compStartMs && compMs < it.compStartMs + it.compDurMs
    } ?: return compMs * 1000L
    if (piece.compDurMs <= 0L) return piece.srcStartMs * 1000L
    val t = (compMs - piece.compStartMs).toDouble() / piece.compDurMs.toDouble()
    return ((piece.srcStartMs + t * piece.srcDurMs) * 1000.0).toLong()
  }

  fun matchesPlayback(plan: ExportPlan): Boolean {
    if (playback[0].size != plan.tracks[0].size || playback[1].size != plan.tracks[1].size) {
      return false
    }
    for (track in playback.indices) {
      for (index in playback[track].indices) {
        val have = playback[track][index]
        val want = plan.tracks[track][index]
        if (have.compStartMs != want.compStartMs ||
          have.compDurMs != want.compDurMs ||
          have.srcStartMs != want.srcStartMs ||
          have.srcDurMs != want.srcDurMs
        ) {
          return false
        }
      }
    }
    return true
  }

  fun matches(plan: ExportPlan): Boolean {
    if (tracks[0].size != plan.tracks[0].size || tracks[1].size != plan.tracks[1].size) {
      return false
    }
    for (track in tracks.indices) {
      for (index in tracks[track].indices) {
        val have = tracks[track][index]
        val want = plan.tracks[track][index]
        if (have.compStartMs != want.compStartMs ||
          have.compDurMs != want.compDurMs ||
          have.srcStartMs != want.srcStartMs ||
          have.srcDurMs != want.srcDurMs ||
          have.hidden != want.hidden
        ) {
          return false
        }
      }
    }
    return true
  }
}

@UnstableApi
private class TransitionCompositor(
  private val width: Int,
  private val height: Int,
  private val mix: TimelineMix,
) : VideoCompositorSettings {
  private var overlayLogs = 0
  private var lastOverlayKey = ""

  override fun getOutputSize(inputSizes: List<Size>): Size = Size(width, height)

  override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
    val ms = presentationTimeUs / 1000L
    val blend = mix.blends.firstOrNull { ms >= it.startMs && ms < it.startMs + it.durationMs }
    val packed = blend != null && (inputId == blend.outgoingTrack || inputId == blend.incomingTrack)
    val covered = covers(inputId, ms)
    val action = when {
      packed -> "pack"
      covered -> "opaque"
      else -> "hidden"
    }
    val key = "$inputId:$action:${blend?.startMs ?: -1}:${ms / 250}"
    if (overlayLogs < 24 || key != lastOverlayKey) {
      Log.i(
        "NativeVideoEngine",
        "composite input=$inputId tUs=$presentationTimeUs ms=$ms action=$action " +
          "blendStart=${blend?.startMs ?: -1} covers=$covered " +
          "windows=${mix.blends.joinToString { "${it.startMs}+${it.durationMs}" }}",
      )
      overlayLogs++
      lastOverlayKey = key
    }
    if (blend != null && packed) return packHalf(inputId == blend.outgoingTrack)
    return if (covered) opaque() else hidden()
  }

  private fun packHalf(left: Boolean): OverlaySettings {
    return StaticOverlaySettings.Builder()
      .setAlphaScale(1f)
      .setScale(0.5f, 1f)
      .setBackgroundFrameAnchor(if (left) -0.5f else 0.5f, 0f)
      .build()
  }

  private fun covers(track: Int, ms: Long): Boolean {
    val pieces = mix.tracks.getOrNull(track) ?: return false
    return pieces.any {
      !it.hidden && ms >= it.compStartMs && ms < it.compStartMs + it.compDurMs
    }
  }

  private fun blendSettings(inputId: Int, blend: BlendWindow, t: Float): OverlaySettings {
    if (motionLayersDrawable(blend.layers)) {
      val (outgoing, incoming) = evaluateMotionPoses(blend.layers, t)
      val pose = if (inputId == blend.outgoingTrack) outgoing else incoming
      return poseSettings(pose)
    }
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

  private fun poseSettings(pose: MotionPose): OverlaySettings {
    if (pose.opacity <= 0.001f || kotlin.math.abs(pose.scale) < 0.001f) return hidden()
    val builder = StaticOverlaySettings.Builder()
      .setAlphaScale(pose.opacity.coerceIn(0f, 1f))
      .setScale(pose.scale, pose.scale)
      .setRotationDegrees(pose.turns * 360f)
    val cx = pose.tx.coerceIn(-1f, 1f)
    val cy = pose.ty.coerceIn(-1f, 1f)
    if (cx != 0f || cy != 0f) {
      builder.setOverlayFrameAnchor(-cx, -cy).setBackgroundFrameAnchor(cx, cy)
    }
    return builder.build()
  }

  private fun opaque(): OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(1f).build()

  private fun hidden(): OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(0f).build()
}

private data class OverlaySpan(
  val startMs: Long,
  val endMs: Long,
  val sourceStartMs: Long,
)

private fun entranceFrameIndex(elapsedMs: Long, durationMs: Int, frameCount: Int): Int {
  if (frameCount <= 1) return 0
  if (durationMs <= 0 || elapsedMs >= durationMs) return frameCount - 1
  if (elapsedMs <= 0L) return 0
  val progress = elapsedMs.toDouble() / durationMs.toDouble()
  return (progress * (frameCount - 1)).roundToInt().coerceIn(0, frameCount - 1)
}

@UnstableApi
private class TimedBitmapOverlay(
  private val overlay: Map<*, *>,
  private val spans: List<OverlaySpan>,
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
    val on = spans.any { ms in it.startMs until it.endMs }
    return StaticOverlaySettings.Builder().setAlphaScale(if (on) 1f else 0f).build()
  }

  private fun imagePath(timeMs: Long): String? {
    val file = overlay["path"] as? String
    if (file != null) return file
    val dir = overlay["sequenceDir"] as? String ?: return null
    val count = (overlay["frameCount"] as? Number)?.toInt() ?: return null
    if (count <= 0) return null
    if (spans.isEmpty()) return null
    val overlayStart = (overlay["overlayStartMs"] as? Number)?.toInt() ?: 0
    val duration = (overlay["entranceDurationMs"] as? Number)?.toInt() ?: 0
    val span = spans.firstOrNull { timeMs in it.startMs until it.endMs } ?: spans.first()
    val elapsed = (span.sourceStartMs - overlayStart + (timeMs - span.startMs)).coerceAtLeast(0L)
    val index = entranceFrameIndex(elapsed, duration, count)
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
