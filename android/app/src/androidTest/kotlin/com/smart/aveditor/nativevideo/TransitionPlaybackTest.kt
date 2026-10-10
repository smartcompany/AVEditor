package com.smart.aveditor.nativevideo

import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Plays a two-clip timeline that contains a transition on a real CompositionPlayer.
 * The player must leave time zero. The audio-only sequence used to abort playback.
 */
@RunWith(AndroidJUnit4::class)
@OptIn(UnstableApi::class)
class TransitionPlaybackTest {
  @Test
  fun transitionTimelineAdvancesPastTheCut() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File(context.cacheDir, "transition-playback.mp4")
    instrumentation.context.assets.open("transition-playback.mp4").use { input ->
      source.outputStream().use { output -> input.copyTo(output) }
    }
    val segments = listOf(
      mapOf(
        "startMs" to 0,
        "endMs" to 2000,
        "transitionDurationMs" to 600,
        "transitionEffect" to "circleopen",
      ),
      mapOf("startMs" to 2000, "endMs" to 4000),
    )
    val preview = NativeVideoEngineMedia.buildTimelinePreview(source.absolutePath, segments)
    val reader = ImageReader.newInstance(
      preview.width,
      preview.height,
      PixelFormat.RGBA_8888,
      3,
    )
    reader.setOnImageAvailableListener({ images ->
      images.acquireLatestImage()?.close()
    }, Handler(Looper.getMainLooper()))

    var error: Throwable? = null
    val player = newTimelinePlayer(context, preview)
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.addListener(object : androidx.media3.common.Player.Listener {
        override fun onPlayerError(playbackException: androidx.media3.common.PlaybackException) {
          error = playbackException
        }
      })
      player.setVideoSurface(reader.surface, Size(preview.width, preview.height))
      player.setComposition(preview.composition)
      player.prepare()
      player.play()
    }

    val deadline = System.currentTimeMillis() + 20_000
    var position = 0L
    while (System.currentTimeMillis() < deadline && error == null && position < 800) {
      Thread.sleep(200)
      InstrumentationRegistry.getInstrumentation().runOnMainSync {
        position = player.currentPosition
      }
    }
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.release()
    }
    reader.close()

    assertNull(error?.toString(), error)
    assertTrue("playback stayed at ${position}ms", position >= 800)
  }

  @Test
  fun hardCutTimelineAdvancesPastTheCut() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File(context.cacheDir, "hard-cut-playback.mp4")
    instrumentation.context.assets.open("transition-playback.mp4").use { input ->
      source.outputStream().use { output -> input.copyTo(output) }
    }
    val segments = listOf(
      mapOf("startMs" to 0, "endMs" to 1500),
      mapOf("startMs" to 1500, "endMs" to 4000),
    )
    val preview = NativeVideoEngineMedia.buildTimelinePreview(source.absolutePath, segments)
    val reader = ImageReader.newInstance(
      preview.width,
      preview.height,
      PixelFormat.RGBA_8888,
      3,
    )
    reader.setOnImageAvailableListener({ images ->
      images.acquireLatestImage()?.close()
    }, Handler(Looper.getMainLooper()))

    var error: Throwable? = null
    val player = newTimelinePlayer(context, preview)
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.addListener(object : androidx.media3.common.Player.Listener {
        override fun onPlayerError(playbackException: androidx.media3.common.PlaybackException) {
          error = playbackException
        }
      })
      player.setVideoSurface(reader.surface, Size(preview.width, preview.height))
      player.setComposition(preview.composition)
      player.prepare()
      player.play()
    }

    val deadline = System.currentTimeMillis() + 20_000
    var position = 0L
    while (System.currentTimeMillis() < deadline && error == null && position < 2500) {
      Thread.sleep(200)
      InstrumentationRegistry.getInstrumentation().runOnMainSync {
        position = player.currentPosition
      }
    }
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.release()
    }
    reader.close()

    assertNull(error?.toString(), error)
    assertTrue("playback stopped at the cut, position=${position}ms", position >= 2500)
  }

  @Test
  fun seekThenPlayAdvances() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File(context.cacheDir, "seek-then-play.mp4")
    instrumentation.context.assets.open("transition-playback.mp4").use { input ->
      source.outputStream().use { output -> input.copyTo(output) }
    }
    val segments = listOf(
      mapOf("startMs" to 0, "endMs" to 4000),
    )
    val preview = NativeVideoEngineMedia.buildTimelinePreview(source.absolutePath, segments)
    val reader = ImageReader.newInstance(
      preview.width,
      preview.height,
      PixelFormat.RGBA_8888,
      3,
    )
    reader.setOnImageAvailableListener({ images ->
      images.acquireLatestImage()?.close()
    }, Handler(Looper.getMainLooper()))

    var error: Throwable? = null
    val player = newTimelinePlayer(context, preview)
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.addListener(object : androidx.media3.common.Player.Listener {
        override fun onPlayerError(playbackException: androidx.media3.common.PlaybackException) {
          error = playbackException
        }
      })
      player.setVideoSurface(reader.surface, Size(preview.width, preview.height))
      player.setComposition(preview.composition)
      player.prepare()
      player.setComposition(preview.composition, 1500)
      player.play()
    }

    val deadline = System.currentTimeMillis() + 20_000
    var position = 0L
    while (System.currentTimeMillis() < deadline && error == null && position < 2500) {
      Thread.sleep(200)
      InstrumentationRegistry.getInstrumentation().runOnMainSync {
        position = player.currentPosition
      }
    }
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      player.release()
    }
    reader.close()

    assertNull(error?.toString(), error)
    assertTrue("playback stayed after seek, position=${position}ms", position >= 2500)
  }
}
