package com.smart.aveditor.nativevideo

import org.junit.Assert.assertEquals
import org.junit.Test

/** Cross-fades keep full brightness: the bottom clip is drawn at min(1, bottom + top). */
class TransitionBlendDrawTest {
  private fun layer(property: String, from: Float, to: Float, target: String) = MotionLayer(
    property = property,
    from = from,
    to = to,
    easing = "linear",
    target = target,
    start = 0f,
    end = 1f,
  )

  private fun blend(layers: List<MotionLayer>, effect: String = "dissolve") = BlendWindow(
    startMs = 0,
    durationMs = 1000,
    effect = effect,
    outgoingTrack = 0,
    incomingTrack = 1,
    layers = layers,
  )

  @Test
  fun dissolve_keepsOutgoingOpaqueUnderIncoming() {
    val draw = resolveBlend(
      blend(listOf(layer("opacity", 1f, 0f, "A"), layer("opacity", 0f, 1f, "B"))),
      0.5f,
    )
    // B (last target) is on top at 0.5 over an opaque A: 0.5·A + 0.5·B.
    assertEquals(false, draw.aOnTop)
    assertEquals(1f, draw.alphaA, 1e-4f)
    assertEquals(0.5f, draw.alphaB, 1e-4f)
  }

  @Test
  fun namedFade_keepsOutgoingOpaque() {
    val draw = resolveBlend(blend(emptyList(), effect = "fade"), 0.3f)
    assertEquals(1f, draw.alphaA, 1e-4f)
    assertEquals(0.3f, draw.alphaB, 1e-4f)
  }

  @Test
  fun slidingFade_isUnchanged() {
    // Clips that slide apart keep their authored opacity (catalog design).
    val draw = resolveBlend(
      blend(
        listOf(
          layer("translateX", 0f, -1f, "A"),
          layer("translateX", 1f, 0f, "B"),
          layer("opacity", 1f, 0f, "A"),
          layer("opacity", 0f, 1f, "B"),
        ),
      ),
      0.5f,
    )
    assertEquals(0.5f, draw.alphaA, 1e-4f)
    assertEquals(0.5f, draw.alphaB, 1e-4f)
  }

  @Test
  fun secondTransition_outgoingIsTrack1() {
    // Three clips alternate tracks 0 → 1 → 0, so the 2nd blend runs 1 → 0.
    val packed = NativeVideoEngineMedia.packSegmentsForEngine(
      listOf(
        mapOf("startMs" to 0, "endMs" to 4000, "transitionDurationMs" to 700, "transitionEffect" to "dissolve"),
        mapOf("startMs" to 4000, "endMs" to 7000, "transitionDurationMs" to 700, "transitionEffect" to "dissolve"),
        mapOf("startMs" to 7000, "endMs" to 10000),
      ),
    )
    val timeline = EnginePlanBuilder.EngineTimeline(
      json = "",
      durationMs = 10000,
      width = 720,
      height = 1280,
      sourcePath = "",
      hasAudio = false,
      blends = packed.blends.toList(),
    )
    val first = timeline.blendDrawAt(packed.blends[0].startMs + 100, 3)!!
    val second = timeline.blendDrawAt(packed.blends[1].startMs + 100, 3)!!
    assertEquals(0, first.outgoingTrack)
    assertEquals(1, second.outgoingTrack)
  }
}
