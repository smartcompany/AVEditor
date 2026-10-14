package com.smart.aveditor.nativevideo

import android.graphics.Bitmap
import java.nio.ByteBuffer

/** One decoded still from a file the platform retriever cannot read. */
internal class FfmpegStill {
  private var handle = 0L
  private var openPath = ""

  fun frames(
    path: String,
    startMs: Long,
    endMs: Long,
    stepMs: Long,
    maxSide: Int,
  ): List<Pair<Long, Bitmap>> {
    if (handle == 0L || openPath != path) {
      close()
      handle = nativeOpen(path)
      openPath = if (handle != 0L) path else ""
    }
    if (handle == 0L) return emptyList()
    val end = if (endMs < startMs) startMs else endMs
    nativeSeek(handle, startMs)
    val kept = ArrayList<Pair<Long, Bitmap>>()
    var lastKept = Long.MIN_VALUE
    val info = IntArray(3)
    while (kept.size < 40) {
      val rgba = nativePull(handle, maxSide, info) ?: break
      val timeMs = info[2].toLong()
      val width = info[0]
      val height = info[1]
      if (timeMs > end + stepMs) break
      val keep = timeMs + 40 >= startMs &&
        (lastKept == Long.MIN_VALUE || timeMs - lastKept >= stepMs) &&
        width >= 2 &&
        height >= 2 &&
        rgba.size >= width * height * 4
      if (!keep) continue
      val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
      bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
      kept.add(timeMs to bitmap)
      lastKept = timeMs
    }
    return kept
  }

  fun frame(path: String, timeMs: Long, maxSide: Int): Bitmap? {
    if (handle == 0L || openPath != path) {
      close()
      handle = nativeOpen(path)
      openPath = if (handle != 0L) path else ""
    }
    if (handle == 0L) return null
    val size = IntArray(2)
    val rgba = nativeFrame(handle, timeMs, maxSide, size) ?: return null
    val width = size[0]
    val height = size[1]
    if (width < 2 || height < 2 || rgba.size < width * height * 4) return null
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
    return bitmap
  }

  fun close() {
    if (handle != 0L) nativeClose(handle)
    handle = 0L
    openPath = ""
  }

  private external fun nativeOpen(path: String): Long
  private external fun nativeClose(handle: Long)
  private external fun nativeSeek(handle: Long, timeMs: Long)
  private external fun nativePull(handle: Long, maxSide: Int, info: IntArray): ByteArray?
  private external fun nativeFrame(handle: Long, timeMs: Long, maxSide: Int, size: IntArray): ByteArray?

  companion object {
    init {
      System.loadLibrary("aveditor_ffmpeg")
    }
  }
}
