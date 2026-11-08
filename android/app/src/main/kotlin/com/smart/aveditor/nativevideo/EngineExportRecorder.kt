package com.smart.aveditor.nativevideo

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface

/** Surface-input H.264 encoder + muxer for [EngineExporter]. */
internal class EngineExportRecorder(
  width: Int,
  height: Int,
  outputPath: String,
) {
  private val encoder: MediaCodec
  val inputSurface: Surface
  private val muxer: MediaMuxer
  private var track = -1
  private var muxerStarted = false
  private val bufferInfo = MediaCodec.BufferInfo()

  init {
    val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
    format.setInteger(
      MediaFormat.KEY_COLOR_FORMAT,
      MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
    )
    format.setInteger(MediaFormat.KEY_BIT_RATE, (width * height * 4).coerceAtLeast(1_500_000))
    format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
    format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
    encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    inputSurface = encoder.createInputSurface()
    muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
  }

  fun start() {
    encoder.start()
  }

  fun drain(end: Boolean = false) {
    if (end) {
      try {
        encoder.signalEndOfInputStream()
      } catch (_: Exception) {
      }
    }
    var spin = 0
    while (spin++ < 64) {
      val out = encoder.dequeueOutputBuffer(bufferInfo, if (end) 10_000 else 0)
      when {
        out == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!end) return else continue
        out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          if (muxerStarted) continue
          track = muxer.addTrack(encoder.outputFormat)
          muxer.start()
          muxerStarted = true
        }
        out >= 0 -> {
          val buf = encoder.getOutputBuffer(out) ?: continue
          if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            bufferInfo.size = 0
          }
          if (bufferInfo.size > 0 && muxerStarted) {
            buf.position(bufferInfo.offset)
            buf.limit(bufferInfo.offset + bufferInfo.size)
            muxer.writeSampleData(track, buf, bufferInfo)
          }
          encoder.releaseOutputBuffer(out, false)
          if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
      }
    }
  }

  fun finish() {
    drain(end = true)
    try {
      encoder.stop()
    } catch (_: Exception) {
    }
    encoder.release()
    inputSurface.release()
    if (muxerStarted) {
      try {
        muxer.stop()
      } catch (_: Exception) {
      }
    }
    muxer.release()
  }
}
