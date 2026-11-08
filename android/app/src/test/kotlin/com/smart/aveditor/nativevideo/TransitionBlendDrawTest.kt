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
}
