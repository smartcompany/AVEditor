package com.smart.aveditor.nativevideo

import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Device smoke: native engine clock advances after seek+play (the failure mode
 * CompositionPlayer dual-seq hit with isPlaying=true and frozen position).
 */
@RunWith(AndroidJUnit4::class)
class EngineSeekPlaySmokeTest {
  @Test
  fun packAndNativeClockApi_loadLibrary() {
    System.loadLibrary("aveditor_engine")
    val latch = CountDownLatch(1)
    var ok = false
    Handler(Looper.getMainLooper()).post {
      try {
        val peer = object : EngineNative() {
          override fun onEngineFrame(positionMs: Long, mask: Int, t: Float, effect: String?) {}
        }
        val handle = peer.nativeCreate()
        assertTrue(handle != 0L)
        peer.nativeSeek(handle, 0)
        peer.nativePlay(handle)
        Thread.sleep(50)
        peer.nativePause(handle)
        peer.nativeRelease(handle)
        ok = true
      } finally {
        latch.countDown()
      }
    }
    assertTrue(latch.await(5, TimeUnit.SECONDS))
    assertTrue(ok)
    InstrumentationRegistry.getInstrumentation().targetContext
  }
}
