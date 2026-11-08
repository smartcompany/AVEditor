package com.smart.aveditor.nativevideo

internal interface TimelineSession {
  val textureId: Long
  val durationMs: Int
  val width: Int
  val height: Int

  fun update(sourcePath: String, segments: List<*>)
  fun start()
  fun play(done: (String?) -> Unit)
  fun playbackSnapshot(): Map<String, Any>
  fun pause()
  fun seekToMs(ms: Long)
  fun prerollToMs(ms: Long, done: (Boolean) -> Unit)
  fun release()
}
