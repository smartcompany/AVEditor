package com.smart.aveditor.nativevideo

import android.view.Surface

/**
 * JNI peer for [libaveditor_engine]. Subclasses implement [onEngineFrame] /
 * [onEngineExportProgress] which native invokes on the jobject passed to [nativeCreate].
 */
internal abstract class EngineNative {
  init {
    System.loadLibrary("aveditor_engine")
  }

  external fun nativeCreate(): Long
  external fun nativeRelease(handle: Long)
  external fun nativeSetPlan(handle: Long, json: String): Int
  external fun nativeSetOutputSurface(handle: Long, surface: Surface?): Int
  external fun nativeSetDecoderSurface(handle: Long, slot: Int, surface: Surface?): Int
  external fun nativePlay(handle: Long)
  external fun nativePause(handle: Long)
  external fun nativeSeek(handle: Long, ms: Long)
  external fun nativePositionMs(handle: Long): Long
  external fun nativeDurationMs(handle: Long): Long
  external fun nativeIsPlaying(handle: Long): Boolean
  external fun nativePump(handle: Long): Int
  external fun nativeCancelExport(handle: Long)
  external fun nativeExport(handle: Long, path: String, width: Int, height: Int): Int

  @Suppress("unused")
  fun nativeOnFrame(positionMs: Long, mask: Int, t: Float, effect: String?) {
    onEngineFrame(positionMs, mask, t, effect)
  }

  @Suppress("unused")
  fun nativeOnExportProgress(progress: Double) {
    onEngineExportProgress(progress)
  }

  protected abstract fun onEngineFrame(positionMs: Long, mask: Int, t: Float, effect: String?)
  protected open fun onEngineExportProgress(progress: Double) {}
}
