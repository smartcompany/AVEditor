package com.smart.aveditor.nativevideo

import androidx.media3.common.C
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItemSequence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Playback keeps one CompositionPlayer sequence. The transition is drawn in the
 * frame effect. Export still uses two video sequences plus the clip audio.
 */
@OptIn(UnstableApi::class)
class TransitionPlaybackCompositionTest {
  @Test
  fun playbackWithTransitionStaysOneSequence() {
    val composition = composition(forPlayback = true, withTransition = true)

    assertEquals(1, composition.sequences.size)
    assertEquals(1, videoSequences(composition))
    assertEquals(0, audioOnlySequences(composition))
    assertEquals(
      VideoCompositorSettings.DEFAULT,
      composition.videoCompositorSettings,
    )
    assertTrue(composition.effects.videoEffects.isNotEmpty())
    val tracks = composition.sequences[0].trackTypes
    assertTrue(tracks.contains(C.TRACK_TYPE_VIDEO))
    assertTrue(tracks.contains(C.TRACK_TYPE_AUDIO))
    assertEquals(1, composition.sequences[0].editedMediaItems.size)
    var sum = 0L
    for (item in composition.sequences[0].editedMediaItems) {
      sum += item.getPresentationDurationUs()
    }
    assertEquals(4_000_000L, sum)
    assertDurationsSet(composition)
  }

  @Test
  fun exportWithTransitionKeepsTheAudioSequence() {
    val composition = composition(forPlayback = false, withTransition = true)

    assertEquals(2, videoSequences(composition))
    assertEquals(1, audioOnlySequences(composition))
    assertDurationsSet(composition)
  }

  @Test
  fun hardCutSplitStaysOneClipSoPlaybackDoesNotStop() {
    val composition = NativeVideoEngineMedia.buildCompositionForTest(
      sourcePath = "/tmp/transition-playback.mp4",
      segments = listOf(
        mapOf("startMs" to 0, "endMs" to 1500),
        mapOf("startMs" to 1500, "endMs" to 4000),
      ),
      hasVideoAudio = true,
      forPlayback = true,
    )

    assertEquals(1, composition.sequences.size)
    assertEquals(1, composition.sequences[0].editedMediaItems.size)
    assertEquals(
      4_000_000L,
      composition.sequences[0].editedMediaItems[0].getPresentationDurationUs(),
    )
  }

  @Test
  fun deletedRangeStaysTwoClips() {
    val composition = NativeVideoEngineMedia.buildCompositionForTest(
      sourcePath = "/tmp/transition-playback.mp4",
      segments = listOf(
        mapOf("startMs" to 0, "endMs" to 1500),
        mapOf("startMs" to 2500, "endMs" to 4000),
      ),
      hasVideoAudio = true,
      forPlayback = true,
    )

    assertEquals(1, videoSequences(composition))
    assertEquals(0, audioOnlySequences(composition))
    assertEquals(2, composition.sequences[0].editedMediaItems.size)
    assertDurationsSet(composition)
  }

  @Test
  fun playbackWithoutTransitionKeepsAudioOnTheFirstSequence() {
    val composition = composition(forPlayback = true, withTransition = false)

    assertEquals(1, composition.sequences.size)
    assertEquals(1, videoSequences(composition))
    assertEquals(0, audioOnlySequences(composition))
    val tracks = composition.sequences[0].trackTypes
    assertTrue(tracks.contains(C.TRACK_TYPE_VIDEO))
    assertTrue(tracks.contains(C.TRACK_TYPE_AUDIO))
    assertEquals(1, composition.sequences[0].editedMediaItems.size)
    assertEquals(
      VideoCompositorSettings.DEFAULT,
      composition.videoCompositorSettings,
    )
    assertTrue(composition.effects.videoEffects.isEmpty())
    assertDurationsSet(composition)
  }

  private fun composition(forPlayback: Boolean, withTransition: Boolean): Composition {
    val segments = if (withTransition) {
      listOf(
        mapOf(
          "startMs" to 0,
          "endMs" to 2000,
          "transitionDurationMs" to 600,
          "transitionEffect" to "circleopen",
        ),
        mapOf("startMs" to 2000, "endMs" to 4000),
      )
    } else {
      listOf(mapOf("startMs" to 0, "endMs" to 4000))
    }
    return NativeVideoEngineMedia.buildCompositionForTest(
      sourcePath = "/tmp/transition-playback.mp4",
      segments = segments,
      hasVideoAudio = true,
      forPlayback = forPlayback,
    )
  }

  private fun videoSequences(composition: Composition): Int {
    return composition.sequences.count { sequence ->
      sequence.trackTypes.contains(C.TRACK_TYPE_VIDEO)
    }
  }

  private fun audioOnlySequences(composition: Composition): Int {
    return composition.sequences.count { sequence ->
      sequence.trackTypes.contains(C.TRACK_TYPE_AUDIO) &&
        !sequence.trackTypes.contains(C.TRACK_TYPE_VIDEO)
    }
  }

  private fun assertDurationsSet(composition: Composition) {
    for (sequence in composition.sequences) {
      assertItemsHaveDuration(sequence)
    }
  }

  private fun assertItemsHaveDuration(sequence: EditedMediaItemSequence) {
    for (item in sequence.editedMediaItems) {
      assertNotEquals(C.TIME_UNSET, item.durationUs)
    }
  }
}
