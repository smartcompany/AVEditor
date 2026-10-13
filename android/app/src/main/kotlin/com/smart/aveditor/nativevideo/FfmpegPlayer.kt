package com.smart.aveditor.nativevideo

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.view.Surface
import java.nio.ByteBuffer

/** Plays one file with the bundled ffmpeg libraries. */
internal class FfmpegPlayer(path: String) {
  private val handle: Long = nativeOpen(path)
  private val sampleRate: Int
  private var audioTrack: AudioTrack? = null
  private var playing = false
  var onFrame: ((ByteBuffer, Int, Int, Long) -> Unit)? = null
  var onGlRelease: (() -> Unit)? = null

  init {
    if (handle == 0L) throw IllegalStateException("ffmpeg open failed")
    sampleRate = nativeSampleRate(handle)
    if (sampleRate > 0) {
      val channel = AudioFormat.CHANNEL_OUT_STEREO
      val min = AudioTrack.getMinBufferSize(
        sampleRate,
        channel,
        AudioFormat.ENCODING_PCM_16BIT,
      ).coerceAtLeast(sampleRate)
      audioTrack = AudioTrack.Builder()
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build(),
        )
        .setAudioFormat(
          AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channel)
            .build(),
        )
        .setBufferSizeInBytes(min * 4)
        .setTransferMode(AudioTrack.MODE_STREAM)
        .build()
    }
  }

  fun setSurface(surface: Surface?, width: Int, height: Int) {
    nativeSetSurface(handle, surface, width, height)
  }

  fun seek(ms: Long) {
    nativeSeek(handle, ms)
  }

  fun seekExact(ms: Long, wait: Boolean) {
    nativeSeekExact(handle, ms, wait)
  }

  fun play() {
    playing = true
    audioTrack?.play()
    nativePlay(handle)
  }

  fun pause() {
    playing = false
    nativePause(handle)
    audioTrack?.pause()
  }

  fun positionMs(): Long = nativePosition(handle)

  fun ended(): Boolean = nativeEnded(handle)

  fun release() {
    playing = false
    nativeClose(handle)
    audioTrack?.release()
    audioTrack = null
  }

  @Suppress("unused")
  private fun onPcm(pcm: ByteArray) {
    audioTrack?.write(pcm, 0, pcm.size)
  }

  @Suppress("unused")
  private fun onAudioReset() {
    val track = audioTrack ?: return
    track.pause()
    track.flush()
    if (playing) track.play()
  }

  @Suppress("unused")
  private fun onVideoFrame(buffer: ByteBuffer, width: Int, height: Int, ptsMs: Long) {
    onFrame?.invoke(buffer, width, height, ptsMs)
  }

  @Suppress("unused")
  private fun onGlRelease() {
    onGlRelease?.invoke()
  }

  private external fun nativeOpen(path: String): Long
  private external fun nativeClose(handle: Long)
  private external fun nativeSetSurface(handle: Long, surface: Surface?, width: Int, height: Int)
  private external fun nativeSeek(handle: Long, ms: Long)
  private external fun nativeSeekExact(handle: Long, ms: Long, wait: Boolean)
  private external fun nativePlay(handle: Long)
  private external fun nativePause(handle: Long)
  private external fun nativePosition(handle: Long): Long
  private external fun nativeEnded(handle: Long): Boolean
  private external fun nativeSampleRate(handle: Long): Int

  companion object {
    init {
      System.loadLibrary("aveditor_ffmpeg")
    }
  }
}
