package com.smartcompany.aveditor.nativevideo

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** Debug-mode NDJSON ingest (session 438ec3). Mirrors to logcat + Flutter events. */
internal object DebugAgentLog {
  private val io = Executors.newSingleThreadExecutor()
  private val main = Handler(Looper.getMainLooper())
  @Volatile var eventSink: EventChannel.EventSink? = null

  fun log(
    location: String,
    message: String,
    hypothesisId: String = "",
    data: Map<String, Any?> = emptyMap(),
    runId: String = "pre",
  ) {
    // #region agent log
    val payload = JSONObject()
    payload.put("sessionId", "438ec3")
    payload.put("runId", runId)
    payload.put("hypothesisId", hypothesisId)
    payload.put("location", location)
    payload.put("message", message)
    payload.put("timestamp", System.currentTimeMillis())
    val dataObj = JSONObject()
    for ((k, v) in data) dataObj.put(k, v ?: JSONObject.NULL)
    payload.put("data", dataObj)
    Log.i("AVDbg", "$location $message $dataObj")
    val sinkMap = HashMap<String, Any?>()
    sinkMap["type"] = "debugAgent"
    sinkMap["location"] = location
    sinkMap["message"] = message
    sinkMap["hypothesisId"] = hypothesisId
    sinkMap["runId"] = runId
    val flat = HashMap<String, Any?>()
    for ((k, v) in data) flat[k] = v
    sinkMap["data"] = flat
    main.post {
      try {
        eventSink?.success(sinkMap)
      } catch (_: Exception) {
      }
    }
    io.execute {
      for (host in arrayOf("10.0.2.2", "127.0.0.1")) {
        try {
          val conn = URL(
            "http://$host:7428/ingest/b7abb55b-de33-4872-9dbf-922c26f0a415",
          ).openConnection() as HttpURLConnection
          conn.connectTimeout = 400
          conn.readTimeout = 600
          conn.requestMethod = "POST"
          conn.setRequestProperty("Content-Type", "application/json")
          conn.setRequestProperty("X-Debug-Session-Id", "438ec3")
          conn.doOutput = true
          conn.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
          conn.responseCode
          conn.disconnect()
          return@execute
        } catch (_: Exception) {
        }
      }
    }
    // #endregion
  }
}
