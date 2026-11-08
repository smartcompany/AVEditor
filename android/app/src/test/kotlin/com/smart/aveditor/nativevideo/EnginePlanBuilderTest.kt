package com.smart.aveditor.nativevideo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EnginePlanBuilderTest {
  @Test
  fun packSegmentsForEngine_twoClipsWithTransition_emitsBlendAndTwoTracks() {
    val segments = listOf(
      mapOf(
        "startMs" to 0,
        "endMs" to 5000,
        "transitionDurationMs" to 700,
        "transitionEffect" to "fade",
      ),
      mapOf(
        "startMs" to 5000,
        "endMs" to 10000,
        "transitionDurationMs" to 0,
        "transitionEffect" to "fade",
      ),
    )
    val plan = NativeVideoEngineMedia.packSegmentsForEngine(segments)
    assertEquals(10000L, plan.totalMs)
    assertEquals(1, plan.blends.size)
    assertTrue(plan.tracks[0].isNotEmpty())
    assertTrue(plan.tracks[1].isNotEmpty())
    assertEquals(700L, plan.blends.first().durationMs)
  }

  @Test
  fun packSegmentsForEngine_hardCutOnly_singleTrackPieces() {
    val plan = NativeVideoEngineMedia.packSegmentsForEngine(
      listOf(
        mapOf("startMs" to 0, "endMs" to 3000, "transitionDurationMs" to 0),
      ),
    )
    assertEquals(3000L, plan.totalMs)
    assertTrue(plan.blends.isEmpty())
    assertTrue(plan.tracks[0].isNotEmpty())
  }
}
