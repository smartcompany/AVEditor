#include "aveditor_engine.h"

#include "json_mini.h"

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <errno.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define LOG_TAG "AVEditorEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct Piece {
  int track = 0;
  int64_t comp_start_ms = 0;
  int64_t comp_dur_ms = 0;
  int64_t src_start_ms = 0;
  int64_t src_dur_ms = 0;
  bool hidden = false;
};

struct Blend {
  int64_t start_ms = 0;
  int64_t duration_ms = 0;
  int outgoing = 0;
  int incoming = 1;
  std::string effect = "fade";
};

struct Plan {
  std::string source_path;
  int64_t total_ms = 0;
  int width = 720;
  int height = 1280;
  std::vector<Piece> pieces;
  std::vector<Blend> blends;
};

struct DecoderSlot {
  AMediaExtractor *extractor = nullptr;
  AMediaCodec *codec = nullptr;
  ANativeWindow *window = nullptr;
  int video_track = -1;
  bool configured = false;
  bool open_failed = false;
  bool input_eos = false;
  bool output_eos = false;
  int64_t pending_src_ms = -1;
  int64_t last_pts_us = -1;
  // Decoded frame whose pts is still ahead of the clock (playback only).
  ssize_t held_index = -1;
  int64_t held_pts_us = -1;
  // Set by an explicit seek so the next pump re-positions the decoder.
  bool force_seek = true;
};

// Playback starts decoding the incoming track this far before its piece so
// the codec is open and the first frame is on its texture when the blend begins.
constexpr int64_t kPrewarmMs = 1500;
// A frame may be shown this much before its pts (≈ half a 30 fps frame).
constexpr int64_t kEarlyToleranceUs = 15000;

int64_t now_us() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(clock::now().time_since_epoch())
      .count();
}

Plan parse_plan(const char *json) {
  Plan plan;
  plan.source_path = jsonmini::read_string(json, "sourcePath");
  plan.total_ms = jsonmini::read_i64(json, "totalMs");
  plan.width = jsonmini::read_int(json, "width", 720);
  plan.height = jsonmini::read_int(json, "height", 1280);
  for (const auto &obj : jsonmini::read_object_array(json, "pieces")) {
    Piece p;
    p.track = jsonmini::read_int(obj.c_str(), "track");
    p.comp_start_ms = jsonmini::read_i64(obj.c_str(), "compStartMs");
    p.comp_dur_ms = jsonmini::read_i64(obj.c_str(), "compDurMs");
    p.src_start_ms = jsonmini::read_i64(obj.c_str(), "srcStartMs");
    p.src_dur_ms = jsonmini::read_i64(obj.c_str(), "srcDurMs");
    p.hidden = jsonmini::read_int(obj.c_str(), "hidden", 0) != 0;
    if (p.comp_dur_ms > 0 && p.src_dur_ms > 0) plan.pieces.push_back(p);
  }
  for (const auto &obj : jsonmini::read_object_array(json, "blends")) {
    Blend b;
    b.start_ms = jsonmini::read_i64(obj.c_str(), "startMs");
    b.duration_ms = jsonmini::read_i64(obj.c_str(), "durationMs");
    b.outgoing = jsonmini::read_int(obj.c_str(), "outgoingTrack");
    b.incoming = jsonmini::read_int(obj.c_str(), "incomingTrack", 1);
    b.effect = jsonmini::read_string(obj.c_str(), "effect");
    if (b.effect.empty()) b.effect = "fade";
    if (b.duration_ms > 0) plan.blends.push_back(b);
  }
  return plan;
}

const Piece *piece_covering(const Plan &plan, int track, int64_t comp_ms) {
  for (const auto &p : plan.pieces) {
    if (p.track != track || p.hidden) continue;
    if (comp_ms >= p.comp_start_ms && comp_ms < p.comp_start_ms + p.comp_dur_ms) return &p;
  }
  return nullptr;
}

int64_t source_ms_at(const Piece &p, int64_t comp_ms) {
  if (p.comp_dur_ms <= 0) return p.src_start_ms;
  double t = static_cast<double>(comp_ms - p.comp_start_ms) / static_cast<double>(p.comp_dur_ms);
  t = std::clamp(t, 0.0, 1.0);
  return p.src_start_ms +
         static_cast<int64_t>(t * static_cast<double>(p.src_dur_ms));
}

void release_slot(DecoderSlot &slot) {
  if (slot.codec) {
    AMediaCodec_stop(slot.codec);
    AMediaCodec_delete(slot.codec);
    slot.codec = nullptr;
  }
  if (slot.extractor) {
    AMediaExtractor_delete(slot.extractor);
    slot.extractor = nullptr;
  }
  slot.configured = false;
  slot.input_eos = false;
  slot.output_eos = false;
  slot.video_track = -1;
  slot.pending_src_ms = -1;
  slot.last_pts_us = -1;
  slot.held_index = -1;
  slot.held_pts_us = -1;
  slot.force_seek = true;
}

bool open_slot(DecoderSlot &slot, const std::string &path, ANativeWindow *window) {
  release_slot(slot);
  if (!window || path.empty()) return false;
  slot.window = window;
  slot.extractor = AMediaExtractor_new();
  // Path-based setDataSource is often AMEDIA_ERROR_UNSUPPORTED on emulators.
  // Prefer a file descriptor (MediaExtractor dups it).
  media_status_t st = AMEDIA_ERROR_UNKNOWN;
  const int fd = open(path.c_str(), O_RDONLY);
  if (fd >= 0) {
    struct stat info {};
    if (fstat(fd, &info) == 0 && info.st_size > 0) {
      st = AMediaExtractor_setDataSourceFd(slot.extractor, fd, 0, info.st_size);
    } else {
      LOGE("fstat failed path=%s errno=%d", path.c_str(), errno);
    }
    close(fd);
  } else {
    LOGE("open failed path=%s errno=%d", path.c_str(), errno);
  }
  if (st != AMEDIA_OK) {
    st = AMediaExtractor_setDataSource(slot.extractor, path.c_str());
  }
  if (st != AMEDIA_OK) {
    LOGE("setDataSource failed %d path=%s", st, path.c_str());
    release_slot(slot);
    slot.open_failed = true;
    return false;
  }
  slot.open_failed = false;
  const size_t tracks = AMediaExtractor_getTrackCount(slot.extractor);
  for (size_t i = 0; i < tracks; ++i) {
    AMediaFormat *fmt = AMediaExtractor_getTrackFormat(slot.extractor, i);
    const char *mime = nullptr;
    AMediaFormat_getString(fmt, AMEDIAFORMAT_KEY_MIME, &mime);
    if (mime && strncmp(mime, "video/", 6) == 0) {
      slot.video_track = static_cast<int>(i);
      AMediaExtractor_selectTrack(slot.extractor, i);
      slot.codec = AMediaCodec_createDecoderByType(mime);
      if (!slot.codec) {
        AMediaFormat_delete(fmt);
        release_slot(slot);
        return false;
      }
      st = AMediaCodec_configure(slot.codec, fmt, window, nullptr, 0);
      AMediaFormat_delete(fmt);
      if (st != AMEDIA_OK) {
        LOGE("configure failed %d", st);
        release_slot(slot);
        return false;
      }
      st = AMediaCodec_start(slot.codec);
      if (st != AMEDIA_OK) {
        LOGE("start failed %d", st);
        release_slot(slot);
        return false;
      }
      slot.configured = true;
      return true;
    }
    AMediaFormat_delete(fmt);
  }
  release_slot(slot);
  return false;
}

void seek_slot(DecoderSlot &slot, int64_t src_ms) {
  if (!slot.configured || !slot.extractor) return;
  const int64_t us = src_ms * 1000;
  AMediaExtractor_seekTo(slot.extractor, us, AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC);
  // flush returns every output buffer, including a held one.
  AMediaCodec_flush(slot.codec);
  slot.input_eos = false;
  slot.output_eos = false;
  slot.pending_src_ms = src_ms;
  slot.last_pts_us = -1;
  slot.held_index = -1;
  slot.held_pts_us = -1;
  slot.force_seek = false;
}

/** True when decoding forward from where the slot is cannot reach [src_ms] quickly. */
bool slot_needs_seek(const DecoderSlot &slot, int64_t src_ms) {
  if (slot.force_seek) return true;
  int64_t at = slot.pending_src_ms;
  if (slot.last_pts_us >= 0) at = slot.last_pts_us / 1000;
  if (slot.held_pts_us >= 0) at = std::min(at, slot.held_pts_us / 1000);
  if (at < 0) return true;
  return src_ms + 100 < at || src_ms > at + 1000;
}

void feed_slot(DecoderSlot &slot) {
  if (slot.input_eos) return;
  for (int i = 0; i < 4; ++i) {
    ssize_t ix = AMediaCodec_dequeueInputBuffer(slot.codec, 0);
    if (ix < 0) break;
    size_t size = 0;
    uint8_t *buf = AMediaCodec_getInputBuffer(slot.codec, ix, &size);
    if (!buf) break;
    ssize_t sample = AMediaExtractor_readSampleData(slot.extractor, buf, size);
    if (sample < 0) {
      AMediaCodec_queueInputBuffer(
          slot.codec, ix, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
      slot.input_eos = true;
      break;
    }
    const int64_t pts = AMediaExtractor_getSampleTime(slot.extractor);
    AMediaCodec_queueInputBuffer(slot.codec, ix, 0, sample, pts, 0);
    AMediaExtractor_advance(slot.extractor);
  }
}

/** Next decoded frame index, or -1. Format/buffer change notices are skipped. */
ssize_t dequeue_frame(DecoderSlot &slot, int64_t *pts_us) {
  for (int i = 0; i < 4; ++i) {
    AMediaCodecBufferInfo info;
    ssize_t ox = AMediaCodec_dequeueOutputBuffer(slot.codec, &info, 0);
    if (ox == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED ||
        ox == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
      continue;
    }
    if (ox < 0) return -1;
    if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) slot.output_eos = true;
    if (info.size <= 0 && (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)) {
      AMediaCodec_releaseOutputBuffer(slot.codec, ox, false);
      return -1;
    }
    *pts_us = info.presentationTimeUs;
    return ox;
  }
  return -1;
}

/**
 * Playback pacing: show the newest frame whose pts has been reached by the
 * clock. A frame that is still in the future stays held in the codec until
 * the clock gets there, so video never runs ahead of the composition time.
 */
bool pump_slot_paced(DecoderSlot &slot, int64_t target_src_ms) {
  if (!slot.configured) return false;
  feed_slot(slot);
  const int64_t target_us = target_src_ms * 1000;
  const int64_t due_us = target_us + kEarlyToleranceUs;
  for (int i = 0; i < 16; ++i) {
    if (slot.held_index < 0) {
      int64_t pts = 0;
      const ssize_t ox = dequeue_frame(slot, &pts);
      if (ox < 0) {
        feed_slot(slot);
        return false;
      }
      slot.held_index = ox;
      slot.held_pts_us = pts;
    }
    if (slot.held_pts_us > due_us) return false;  // still in the future: keep holding

    // Held frame is due. If a newer frame is due too, drop this one (catch-up).
    int64_t next_pts = 0;
    const ssize_t next = dequeue_frame(slot, &next_pts);
    if (next >= 0 && next_pts <= due_us) {
      AMediaCodec_releaseOutputBuffer(slot.codec, slot.held_index, false);
      slot.held_index = next;
      slot.held_pts_us = next_pts;
      feed_slot(slot);
      continue;
    }
    // One render per pump: the newest due frame.
    AMediaCodec_releaseOutputBuffer(slot.codec, slot.held_index, true);
    slot.last_pts_us = slot.held_pts_us;
    slot.held_index = next;  // -1 or a future frame
    slot.held_pts_us = next >= 0 ? next_pts : -1;
    feed_slot(slot);
    return true;
  }
  // Still catching up after many drops: show the newest so the picture moves.
  if (slot.held_index >= 0 && slot.held_pts_us <= due_us) {
    AMediaCodec_releaseOutputBuffer(slot.codec, slot.held_index, true);
    slot.last_pts_us = slot.held_pts_us;
    slot.held_index = -1;
    slot.held_pts_us = -1;
    return true;
  }
  return false;
}

/** Export: seek per frame, render the first frame at or near the target. */
bool pump_slot(DecoderSlot &slot, int64_t target_src_ms, bool render) {
  if (!slot.configured) return false;
  bool framed = false;

  for (int i = 0; i < 4; ++i) {
    ssize_t ix = AMediaCodec_dequeueInputBuffer(slot.codec, 0);
    if (ix < 0) break;
    size_t size = 0;
    uint8_t *buf = AMediaCodec_getInputBuffer(slot.codec, ix, &size);
    if (!buf) break;
    ssize_t sample = AMediaExtractor_readSampleData(slot.extractor, buf, size);
    if (sample < 0) {
      AMediaCodec_queueInputBuffer(
          slot.codec, ix, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
      slot.input_eos = true;
      break;
    }
    const int64_t pts = AMediaExtractor_getSampleTime(slot.extractor);
    AMediaCodec_queueInputBuffer(slot.codec, ix, 0, sample, pts, 0);
    AMediaExtractor_advance(slot.extractor);
  }

  for (int i = 0; i < 8; ++i) {
    AMediaCodecBufferInfo info;
    ssize_t ox = AMediaCodec_dequeueOutputBuffer(slot.codec, &info, 0);
    if (ox == AMEDIACODEC_INFO_TRY_AGAIN_LATER) break;
    if (ox == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) continue;
    if (ox == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
    if (ox < 0) break;
    const int64_t pts_ms = info.presentationTimeUs / 1000;
    const bool past = pts_ms + 20 >= target_src_ms;
    const bool do_render = render && past;
    AMediaCodec_releaseOutputBuffer(slot.codec, ox, do_render);
    if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) slot.output_eos = true;
    if (do_render) {
      slot.last_pts_us = info.presentationTimeUs;
      framed = true;
      break;
    }
  }
  return framed;
}

}  // namespace

struct AveditorEngine {
  JavaVM *vm = nullptr;
  jobject j_engine = nullptr;  // global ref
  jmethodID on_progress = nullptr;
  jmethodID on_need_compose = nullptr;

  std::mutex mu;
  Plan plan;
  DecoderSlot slots[2];
  ANativeWindow *output_window = nullptr;  // unused for decode; GL writes here in Kotlin

  std::atomic<bool> playing{false};
  std::atomic<bool> cancel_export{false};
  int64_t position_ms = 0;
  int64_t anchor_pos_ms = 0;
  int64_t anchor_us = 0;
  bool has_anchor = false;
};

static void ensure_slots_for_position(AveditorEngine *engine, int64_t pos) {
  int want_a = 0;
  int want_b = 0;
  float t = 0.f;
  char effect[32] = {};
  aveditor_engine_active_slots(engine, &want_a, &want_b, &t, effect, 32);

  for (int slot = 0; slot < 2; ++slot) {
    const bool want = (slot == 0 && want_a) || (slot == 1 && want_b);
    if (!want) {
      if (engine->slots[slot].configured) release_slot(engine->slots[slot]);
      continue;
    }
    if (!engine->slots[slot].window) continue;
    if (engine->slots[slot].open_failed) continue;
    if (!engine->slots[slot].configured) {
      if (!open_slot(engine->slots[slot], engine->plan.source_path, engine->slots[slot].window)) {
        LOGE("open_slot %d failed", slot);
        continue;
      }
    }
    const Piece *piece = piece_covering(engine->plan, slot, pos);
    if (!piece) continue;
    const int64_t src = source_ms_at(*piece, pos);
    if (engine->slots[slot].pending_src_ms < 0 ||
        std::llabs(engine->slots[slot].pending_src_ms - src) > 80) {
      seek_slot(engine->slots[slot], src);
    }
  }
}

/**
 * Source time [slot] should be decoding at composition time [pos]: the piece
 * on screen now, or the start of its next piece when that begins within
 * [kPrewarmMs] (so the blend's incoming picture is ready on time).
 */
static bool playback_target(const Plan &plan, int slot, int64_t pos, int64_t *src_ms) {
  if (const Piece *piece = piece_covering(plan, slot, pos)) {
    *src_ms = source_ms_at(*piece, pos);
    return true;
  }
  const Piece *next = nullptr;
  for (const auto &p : plan.pieces) {
    if (p.track != slot || p.hidden || p.comp_start_ms <= pos) continue;
    if (p.comp_start_ms - pos > kPrewarmMs) continue;
    if (!next || p.comp_start_ms < next->comp_start_ms) next = &p;
  }
  if (!next) return false;
  *src_ms = next->src_start_ms;
  return true;
}

/** Playback: both decoders stay open; each one decodes toward its target. */
static int pump_playback_slots(AveditorEngine *engine, int64_t pos) {
  int framed = 0;
  for (int slot = 0; slot < 2; ++slot) {
    DecoderSlot &s = engine->slots[slot];
    int64_t src = 0;
    if (!playback_target(engine->plan, slot, pos, &src)) continue;
    if (!s.configured) {
      if (!s.window || s.open_failed) continue;
      if (!open_slot(s, engine->plan.source_path, s.window)) {
        LOGE("open_slot %d failed", slot);
        continue;
      }
    }
    if (slot_needs_seek(s, src)) seek_slot(s, src);
    if (pump_slot_paced(s, src)) framed = 1;
  }
  return framed;
}

AveditorEngine *aveditor_engine_create(JNIEnv *env, jobject j_engine) {
  auto *engine = new AveditorEngine();
  env->GetJavaVM(&engine->vm);
  engine->j_engine = env->NewGlobalRef(j_engine);
  jclass cls = env->GetObjectClass(j_engine);
  engine->on_progress = env->GetMethodID(cls, "nativeOnExportProgress", "(D)V");
  engine->on_need_compose = env->GetMethodID(cls, "nativeOnFrame", "(JIFLjava/lang/String;)V");
  return engine;
}

void aveditor_engine_release(AveditorEngine *engine) {
  if (!engine) return;
  std::lock_guard<std::mutex> lock(engine->mu);
  release_slot(engine->slots[0]);
  release_slot(engine->slots[1]);
  if (engine->output_window) {
    ANativeWindow_release(engine->output_window);
    engine->output_window = nullptr;
  }
  if (engine->vm && engine->j_engine) {
    JNIEnv *env = nullptr;
    if (engine->vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK) {
      env->DeleteGlobalRef(engine->j_engine);
    }
  }
  delete engine;
}

int aveditor_engine_set_plan(AveditorEngine *engine, const char *json_utf8) {
  if (!engine || !json_utf8) return -1;
  std::lock_guard<std::mutex> lock(engine->mu);
  release_slot(engine->slots[0]);
  release_slot(engine->slots[1]);
  engine->slots[0].open_failed = false;
  engine->slots[1].open_failed = false;
  engine->plan = parse_plan(json_utf8);
  engine->position_ms = 0;
  engine->has_anchor = false;
  engine->playing = false;
  LOGI(
      "plan path=%s totalMs=%lld pieces=%zu blends=%zu",
      engine->plan.source_path.c_str(),
      (long long)engine->plan.total_ms,
      engine->plan.pieces.size(),
      engine->plan.blends.size());
  return 0;
}

int aveditor_engine_set_output_surface(JNIEnv *env, AveditorEngine *engine, jobject surface) {
  if (!engine) return -1;
  std::lock_guard<std::mutex> lock(engine->mu);
  if (engine->output_window) {
    ANativeWindow_release(engine->output_window);
    engine->output_window = nullptr;
  }
  if (surface) {
    engine->output_window = ANativeWindow_fromSurface(env, surface);
  }
  return 0;
}

int aveditor_engine_set_decoder_surface(
    JNIEnv *env, AveditorEngine *engine, int slot, jobject surface) {
  if (!engine || slot < 0 || slot > 1) return -1;
  std::lock_guard<std::mutex> lock(engine->mu);
  release_slot(engine->slots[slot]);
  if (engine->slots[slot].window) {
    // window owned by Surface/SurfaceTexture; only detach pointer
    engine->slots[slot].window = nullptr;
  }
  if (surface) {
    engine->slots[slot].window = ANativeWindow_fromSurface(env, surface);
  }
  return 0;
}

void aveditor_engine_play(AveditorEngine *engine) {
  if (!engine) return;
  std::lock_guard<std::mutex> lock(engine->mu);
  engine->playing = true;
  engine->anchor_pos_ms = engine->position_ms;
  engine->anchor_us = now_us();
  engine->has_anchor = true;
}

void aveditor_engine_pause(AveditorEngine *engine) {
  if (!engine) return;
  std::lock_guard<std::mutex> lock(engine->mu);
  if (engine->playing && engine->has_anchor) {
    engine->position_ms = engine->anchor_pos_ms + (now_us() - engine->anchor_us) / 1000;
  }
  engine->playing = false;
  engine->has_anchor = false;
}

void aveditor_engine_seek(AveditorEngine *engine, int64_t position_ms) {
  if (!engine) return;
  std::lock_guard<std::mutex> lock(engine->mu);
  engine->position_ms = std::clamp(position_ms, (int64_t)0, std::max(engine->plan.total_ms, (int64_t)0));
  engine->anchor_pos_ms = engine->position_ms;
  engine->anchor_us = now_us();
  engine->has_anchor = engine->playing.load();
  engine->slots[0].force_seek = true;
  engine->slots[1].force_seek = true;
}

int64_t aveditor_engine_position_ms(AveditorEngine *engine) {
  if (!engine) return 0;
  std::lock_guard<std::mutex> lock(engine->mu);
  if (engine->playing && engine->has_anchor) {
    engine->position_ms = engine->anchor_pos_ms + (now_us() - engine->anchor_us) / 1000;
    if (engine->position_ms >= engine->plan.total_ms) {
      engine->position_ms = engine->plan.total_ms;
      engine->playing = false;
      engine->has_anchor = false;
    }
  }
  return engine->position_ms;
}

int64_t aveditor_engine_duration_ms(AveditorEngine *engine) {
  if (!engine) return 0;
  std::lock_guard<std::mutex> lock(engine->mu);
  return engine->plan.total_ms;
}

int aveditor_engine_is_playing(AveditorEngine *engine) {
  return engine && engine->playing.load() ? 1 : 0;
}

void aveditor_engine_active_slots(
    AveditorEngine *engine, int *out_a, int *out_b, float *blend_t, char *effect, int effect_cap) {
  if (out_a) *out_a = 0;
  if (out_b) *out_b = 0;
  if (blend_t) *blend_t = 0.f;
  if (effect && effect_cap > 0) effect[0] = 0;
  if (!engine) return;
  const int64_t pos = engine->position_ms;
  for (const auto &b : engine->plan.blends) {
    if (pos >= b.start_ms && pos < b.start_ms + b.duration_ms) {
      if (out_a) *out_a = 1;
      if (out_b) *out_b = 1;
      if (blend_t) {
        *blend_t = b.duration_ms > 0
                       ? static_cast<float>(pos - b.start_ms) / static_cast<float>(b.duration_ms)
                       : 1.f;
      }
      if (effect && effect_cap > 0) {
        strncpy(effect, b.effect.c_str(), effect_cap - 1);
        effect[effect_cap - 1] = 0;
      }
      return;
    }
  }
  // Solo: whichever track has a visible piece.
  if (piece_covering(engine->plan, 0, pos)) {
    if (out_a) *out_a = 1;
  } else if (piece_covering(engine->plan, 1, pos)) {
    if (out_b) *out_b = 1;
  } else if (out_a) {
    *out_a = 1;
  }
}

int aveditor_engine_pump(AveditorEngine *engine) {
  if (!engine) return 0;
  std::lock_guard<std::mutex> lock(engine->mu);
  if (engine->playing && engine->has_anchor) {
    engine->position_ms = engine->anchor_pos_ms + (now_us() - engine->anchor_us) / 1000;
    if (engine->position_ms >= engine->plan.total_ms) {
      engine->position_ms = engine->plan.total_ms;
      engine->playing = false;
      engine->has_anchor = false;
    }
  }
  const int64_t pos = engine->position_ms;
  const int framed = pump_playback_slots(engine, pos);

  if (framed && engine->vm && engine->j_engine && engine->on_need_compose) {
    JNIEnv *env = nullptr;
    bool attached = false;
    if (engine->vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
      if (engine->vm->AttachCurrentThread(&env, nullptr) == JNI_OK) attached = true;
    }
    if (env) {
      int a = 0, b = 0;
      float t = 0.f;
      char effect[64] = {};
      aveditor_engine_active_slots(engine, &a, &b, &t, effect, 64);
      const int mask = (a ? 1 : 0) | (b ? 2 : 0);
      jstring jEffect = env->NewStringUTF(effect);
      env->CallVoidMethod(engine->j_engine, engine->on_need_compose, (jlong)pos, mask, t, jEffect);
      env->DeleteLocalRef(jEffect);
      if (attached) engine->vm->DetachCurrentThread();
    }
  }
  return framed;
}

void aveditor_engine_cancel_export(AveditorEngine *engine) {
  if (engine) engine->cancel_export = true;
}

int aveditor_engine_export(AveditorEngine *engine, const char *path_utf8, int width, int height) {
  if (!engine || !path_utf8) return -1;
  engine->cancel_export = false;
  // Export is driven from Kotlin (compose → encoder). Native advances the
  // composition clock in discrete frame steps and pumps decoders.
  std::lock_guard<std::mutex> lock(engine->mu);
  if (engine->plan.total_ms <= 0) return -1;
  const int fps = 30;
  const int64_t frame_ms = 1000 / fps;
  engine->playing = false;
  engine->has_anchor = false;
  for (int64_t pos = 0; pos <= engine->plan.total_ms; pos += frame_ms) {
    if (engine->cancel_export.load()) return -2;
    engine->position_ms = pos;
    engine->slots[0].pending_src_ms = -1;
    engine->slots[1].pending_src_ms = -1;
    ensure_slots_for_position(engine, pos);
    for (int slot = 0; slot < 2; ++slot) {
      if (!engine->slots[slot].configured) continue;
      const Piece *piece = piece_covering(engine->plan, slot, pos);
      if (!piece) continue;
      seek_slot(engine->slots[slot], source_ms_at(*piece, pos));
      for (int tries = 0; tries < 32; ++tries) {
        if (pump_slot(engine->slots[slot], source_ms_at(*piece, pos), true)) break;
      }
    }
    if (engine->vm && engine->j_engine && engine->on_progress) {
      JNIEnv *env = nullptr;
      bool attached = false;
      if (engine->vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (engine->vm->AttachCurrentThread(&env, nullptr) == JNI_OK) attached = true;
      }
      if (env) {
        const double p =
            engine->plan.total_ms > 0 ? static_cast<double>(pos) / engine->plan.total_ms : 1.0;
        env->CallVoidMethod(engine->j_engine, engine->on_progress, p);
        if (engine->on_need_compose) {
          int a = 0, b = 0;
          float t = 0.f;
          char effect[64] = {};
          aveditor_engine_active_slots(engine, &a, &b, &t, effect, 64);
          const int mask = (a ? 1 : 0) | (b ? 2 : 0);
          jstring jEffect = env->NewStringUTF(effect);
          env->CallVoidMethod(
              engine->j_engine, engine->on_need_compose, (jlong)pos, mask, t, jEffect);
          env->DeleteLocalRef(jEffect);
        }
        if (attached) engine->vm->DetachCurrentThread();
      }
    }
  }
  (void)width;
  (void)height;
  (void)path_utf8;
  return 0;
}
