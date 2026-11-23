package com.smartcompany.aveditor.nativevideo

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
     * Transition pose at composition time [positionMs].
     * Mid-cuts need both tracks ([mask] == 3); end-cut → black only needs the
     * outgoing slot.
     */
    fun blendDrawAt(positionMs: Long, mask: Int): BlendDraw? {
      val blend = blends.firstOrNull {
        positionMs >= it.startMs && positionMs < it.startMs + it.durationMs
      } ?: return null
      val outgoingBit = if (blend.outgoingTrack == 0) 1 else 2
      val dual = mask == 3
      val soloOutro = blend.toBlack && (mask and outgoingBit) != 0
      if (!dual && !soloOutro) return null
      val t = if (blend.durationMs <= 0L) 1f
      else ((positionMs - blend.startMs).toFloat() / blend.durationMs.toFloat()).coerceIn(0f, 1f)
      return resolveBlend(blend, t).also {
        it.outgoingTrack = blend.outgoingTrack
        it.toBlack = blend.toBlack
      }
    }
  }

  fun build(
    sourcePath: String,
    segments: List<*>,
    /** Video ∪ music ∪ text end; past picture is black (no pieces). */
    requestedDurationMs: Int = 0,
  ): EngineTimeline {
    // Canvas size follows the first timeline video, not a stale project
    // sourcePath left behind after clips were deleted and replaced.
    val probePath =
      NativeVideoEngineMedia.firstVideoPath(segments, sourcePath) ?: sourcePath
    val meta = NativeVideoEngineMedia.probeOriented(probePath)
    val packed = NativeVideoEngineMedia.packSegmentsForEngine(segments, sourcePath)
    val totalMs = maxOf(packed.totalMs, requestedDurationMs.toLong().coerceAtLeast(0L))
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
            .put("sourcePath", piece.sourcePath.ifBlank { sourcePath })
            .put("kind", piece.mediaKind)
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
          .put("toBlack", blend.toBlack)
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
      .put("totalMs", totalMs)
      .put("width", meta.width)
      .put("height", meta.height)
      .put("pieces", pieces)
      .put("blends", blends)
    return EngineTimeline(
      json = root.toString(),
      durationMs = totalMs.toInt().coerceAtLeast(0),
      width = meta.width,
      height = meta.height,
      sourcePath = sourcePath,
      hasAudio = meta.hasAudio,
      blends = packed.blends.toList(),
    )
  }
}
