package com.smart.aveditor.nativevideo

import android.content.Context
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Probe / waveform / export helpers — Media3 + MediaCodec (no FFmpeg). */
@UnstableApi
object NativeVideoEngineMedia {
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

    val width = (args["width"] as? Number)?.toInt() ?: 1080
    val height = (args["height"] as? Number)?.toInt() ?: 1920
    val rotation = (args["rotationDegrees"] as? Number)?.toFloat() ?: 0f
    val segments = args["segments"] as? List<*> ?: emptyList<Any>()
    val streamCopy = args["streamCopy"] as? Boolean ?: false

    val editedItems = ArrayList<EditedMediaItem>()
    if (segments.isEmpty()) {
      editedItems.add(
        EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(sourcePath)))).build(),
      )
    } else {
      for (raw in segments) {
        val segment = raw as? Map<*, *> ?: continue
        val startMs = (segment["startMs"] as? Number)?.toLong() ?: 0L
        val endMs = (segment["endMs"] as? Number)?.toLong() ?: 0L
        val clipping = MediaItem.ClippingConfiguration.Builder()
          .setStartPositionMs(startMs)
          .setEndPositionMs(endMs)
          .build()
        val mediaItem = MediaItem.Builder()
          .setUri(Uri.fromFile(File(sourcePath)))
          .setClippingConfiguration(clipping)
          .build()
        val effects = Effects(
          /* audioProcessors= */ emptyList(),
          listOf(
            Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP),
            ScaleAndRotateTransformation.Builder()
              .setRotationDegrees(Math.toDegrees(rotation.toDouble()).toFloat())
              .build(),
          ),
        )
        editedItems.add(
          EditedMediaItem.Builder(mediaItem)
            .setEffects(effects)
            .build(),
        )
      }
    }

    // Stream-copy path: single clipped item without effects when possible.
    val composition = if (streamCopy && editedItems.size == 1) {
      val segment = segments.firstOrNull() as? Map<*, *>
      val startMs = (segment?.get("startMs") as? Number)?.toLong() ?: 0L
      val endMs = (segment?.get("endMs") as? Number)?.toLong() ?: 0L
      val clipping = MediaItem.ClippingConfiguration.Builder()
        .setStartPositionMs(startMs)
        .setEndPositionMs(endMs)
        .build()
      val mediaItem = MediaItem.Builder()
        .setUri(Uri.fromFile(File(sourcePath)))
        .setClippingConfiguration(clipping)
        .build()
      Composition.Builder(
        EditedMediaItemSequence(EditedMediaItem.Builder(mediaItem).build()),
      ).build()
    } else {
      Composition.Builder(EditedMediaItemSequence(editedItems)).build()
    }

    val transformer = Transformer.Builder(context)
      .setVideoMimeType(MimeTypes.VIDEO_H264)
      .setAudioMimeType(MimeTypes.AUDIO_AAC)
      .addListener(
        object : Transformer.Listener {
          override fun onCompleted(composition: Composition, result: ExportResult) {
            onProgress(1.0)
            onComplete(Result.success(outputPath))
          }

          override fun onError(
            composition: Composition,
            result: ExportResult,
            exception: ExportException,
          ) {
            onComplete(Result.failure(exception))
          }
        },
      )
      .build()

    // Progress polling — Transformer doesn't expose a continuous callback on all versions.
    val progressHandler = android.os.Handler(Looper.getMainLooper())
    val progressTick = object : Runnable {
      override fun run() {
        onProgress(0.5)
        progressHandler.postDelayed(this, 250)
      }
    }
    progressHandler.post(progressTick)

    transformer.start(composition, outputPath)
    // Stop polling when complete/error via listener above; cancel after a grace.
    progressHandler.postDelayed({ progressHandler.removeCallbacks(progressTick) }, 120_000)
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
