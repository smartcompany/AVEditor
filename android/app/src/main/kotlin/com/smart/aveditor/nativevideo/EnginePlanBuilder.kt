package com.smart.aveditor.nativevideo

import org.json.JSONArray
import org.json.JSONObject

/**
 * Packs timeline segments the same way export/iOS do, then serializes a plan for
 * [TimelineEngineSession] / libaveditor_engine (no Media3 Composition).
 */
internal object EnginePlanBuilder {
  data class EngineTimeline(
    val json: String,
    val durationMs: Int,
    val width: Int,
    val height: Int,
    val sourcePath: String,
    val hasAudio: Boolean,
    val blends: List<BlendWindow> = emptyList(),
  ) {
    /**
     * Transition pose at composition time [positionMs] when both tracks are on
     * screen ([mask] == 3). Same window rule as libaveditor_engine.
     */
    fun blendDrawAt(positionMs: Long, mask: Int): BlendDraw? {
      if (mask != 3) return null
      val blend = blends.firstOrNull {
        positionMs >= it.startMs && positionMs < it.startMs + it.durationMs
      } ?: return null
      val t = if (blend.durationMs <= 0L) 1f
      else ((positionMs - blend.startMs).toFloat() / blend.durationMs.toFloat()).coerceIn(0f, 1f)
      return resolveBlend(blend, t).also { it.outgoingTrack = blend.outgoingTrack }
    }
  }

  fun build(sourcePath: String, segments: List<*>): EngineTimeline {
    val meta = NativeVideoEngineMedia.probeOriented(sourcePath)
    val packed = NativeVideoEngineMedia.packSegmentsForEngine(segments)
    val pieces = JSONArray()
    for (track in 0..1) {
      for (piece in packed.tracks[track]) {
        if (piece.hidden) continue
        pieces.put(
          JSONObject()
            .put("track", track)
            .put("compStartMs", piece.compStartMs)
            .put("compDurMs", piece.compDurMs)
            .put("srcStartMs", piece.srcStartMs)
            .put("srcDurMs", piece.srcDurMs)
            .put("hidden", false),
        )
      }
    }
    val blends = JSONArray()
    for (blend in packed.blends) {
      blends.put(
        JSONObject()
          .put("startMs", blend.startMs)
          .put("durationMs", blend.durationMs)
          .put("outgoingTrack", blend.outgoingTrack)
          .put("incomingTrack", blend.incomingTrack)
          .put("effect", blend.effect)
          .put("kind", blend.kind)
          .put("reverse", blend.reverse)
          .put("edge", blend.edge)
          .put("scaleFrom", blend.scaleFrom)
          .put("scaleTo", blend.scaleTo),
      )
    }
    val root = JSONObject()
      .put("sourcePath", sourcePath)
      .put("totalMs", packed.totalMs)
      .put("width", meta.width)
      .put("height", meta.height)
      .put("pieces", pieces)
      .put("blends", blends)
    return EngineTimeline(
      json = root.toString(),
      durationMs = packed.totalMs.toInt().coerceAtLeast(0),
      width = meta.width,
      height = meta.height,
      sourcePath = sourcePath,
      hasAudio = meta.hasAudio,
      blends = packed.blends.toList(),
    )
  }
}
