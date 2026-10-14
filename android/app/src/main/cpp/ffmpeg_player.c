#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#define LOG_TAG "AVEditor"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

typedef struct FfPlayer {
  AVFormatContext *fmt;
  AVCodecContext *video;
  AVCodecContext *audio;
  SwsContext *sws;
  SwrContext *swr;
  AVFrame *vframe;
  AVFrame *aframe;
  AVPacket *packet;
  int video_index;
  int audio_index;
  AVRational video_tb;
  int rotation;
  int out_w;
  int out_h;
  int sws_w;
  int sws_h;
  int sws_src_w;
  int sws_src_h;
  int sws_src_fmt;
  uint8_t *scaled;
  int scaled_stride;
  uint8_t *presented;
  int presented_bytes;
  int sample_rate;
  int channels;
  int64_t duration_ms;
  ANativeWindow *window;
  JavaVM *vm;
  jobject self;
  jmethodID on_pcm;
  jmethodID on_audio_reset;
  jmethodID on_frame;
  jmethodID on_gl_release;
  JNIEnv *play_env;
  int play_attached;
  pthread_t thread;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int thread_started;
  int stop;
  int playing;
  int seek_req;
  int seek_exact;
  int64_t seek_ms;
  int present_gen;
  int present_wait;
  int64_t position_ms;
  int64_t demux_ms;
  int demux_ready;
  int ended;
  int64_t clock_origin_ms;
  int64_t clock_origin_mono;
  int clock_ready;
  int64_t audio_samples;
} FfPlayer;

static int64_t mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int display_rotation(const AVStream *stream) {
  const AVPacketSideData *side = av_packet_side_data_get(
      stream->codecpar->coded_side_data,
      stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX);
  if (side == NULL || side->data == NULL || side->size < 9 * (int)sizeof(int32_t)) {
    return 0;
  }
  double ccw = av_display_rotation_get((const int32_t *)side->data);
  if (isnan(ccw)) return 0;
  int clockwise = (int)lrint(-ccw) % 360;
  if (clockwise < 0) clockwise += 360;
  if (clockwise == 90 || clockwise == 180 || clockwise == 270) return clockwise;
  return 0;
}

static void release_sws(FfPlayer *player) {
  sws_freeContext(player->sws);
  player->sws = NULL;
  free(player->scaled);
  player->scaled = NULL;
  free(player->presented);
  player->presented = NULL;
  player->presented_bytes = 0;
}

static int ensure_sws(FfPlayer *player, const AVFrame *frame) {
  int rot = player->rotation;
  int dst_w = (rot == 90 || rot == 270) ? player->out_h : player->out_w;
  int dst_h = (rot == 90 || rot == 270) ? player->out_w : player->out_h;
  if (dst_w < 2) dst_w = 2;
  if (dst_h < 2) dst_h = 2;
  if (player->sws != NULL &&
      player->sws_src_w == frame->width &&
      player->sws_src_h == frame->height &&
      player->sws_src_fmt == frame->format &&
      player->sws_w == dst_w &&
      player->sws_h == dst_h) {
    return 0;
  }
  release_sws(player);
  player->sws = sws_getContext(
      frame->width, frame->height, (enum AVPixelFormat)frame->format,
      dst_w, dst_h, AV_PIX_FMT_RGBA,
      SWS_BILINEAR, NULL, NULL, NULL);
  if (player->sws == NULL) return -1;
  player->scaled_stride = dst_w * 4;
  player->scaled = (uint8_t *)malloc((size_t)player->scaled_stride * (size_t)dst_h);
  if (player->scaled == NULL) {
    release_sws(player);
    return -1;
  }
  player->sws_w = dst_w;
  player->sws_h = dst_h;
  player->sws_src_w = frame->width;
  player->sws_src_h = frame->height;
  player->sws_src_fmt = frame->format;
  return 0;
}

static void put_pixel(
    uint8_t *dst, int stride_px, int x, int y, const uint8_t *px) {
  memcpy(dst + ((size_t)y * (size_t)stride_px + (size_t)x) * 4, px, 4);
}

static void blit(FfPlayer *player, uint8_t *dst, int stride, int dw, int dh) {
  int sw = player->sws_w;
  int sh = player->sws_h;
  const uint8_t *src = player->scaled;
  int rot = player->rotation;
  if (rot == 0) {
    int copy_w = sw < dw ? sw : dw;
    int copy_h = sh < dh ? sh : dh;
    for (int y = 0; y < copy_h; y++) {
      memcpy(
          dst + (size_t)y * (size_t)stride * 4,
          src + (size_t)y * (size_t)player->scaled_stride,
          (size_t)copy_w * 4);
    }
    return;
  }
  for (int sy = 0; sy < sh; sy++) {
    for (int sx = 0; sx < sw; sx++) {
      int dx = sx;
      int dy = sy;
      if (rot == 90) {
        dx = sh - 1 - sy;
        dy = sx;
      } else if (rot == 180) {
        dx = sw - 1 - sx;
        dy = sh - 1 - sy;
      } else if (rot == 270) {
        dx = sy;
        dy = sw - 1 - sx;
      }
      if (dx < 0 || dy < 0 || dx >= dw || dy >= dh) continue;
      put_pixel(
          dst, stride, dx, dy,
          src + (size_t)sy * (size_t)player->scaled_stride + (size_t)sx * 4);
    }
  }
}

static int64_t frame_ms(const FfPlayer *player, const AVFrame *frame);
static void emit_frame(FfPlayer *player, int64_t pts_ms);

static void present_frame(FfPlayer *player, const AVFrame *frame) {
  if (ensure_sws(player, frame) != 0) return;
  uint8_t *planes[4] = {player->scaled, NULL, NULL, NULL};
  int strides[4] = {player->scaled_stride, 0, 0, 0};
  sws_scale(
      player->sws, (const uint8_t *const *)frame->data, frame->linesize,
      0, frame->height, planes, strides);

  int bytes = player->out_w * player->out_h * 4;
  if (bytes <= 0) return;
  if (player->presented_bytes != bytes) {
    free(player->presented);
    player->presented = (uint8_t *)malloc((size_t)bytes);
    player->presented_bytes = player->presented == NULL ? 0 : bytes;
  }
  if (player->presented == NULL) return;
  blit(player, player->presented, player->out_w, player->out_w, player->out_h);
  emit_frame(player, frame_ms(player, frame));
  pthread_mutex_lock(&player->mu);
  player->present_gen += 1;
  if (player->present_wait) pthread_cond_broadcast(&player->cv);
  pthread_mutex_unlock(&player->mu);
}

static int64_t frame_ms(const FfPlayer *player, const AVFrame *frame) {
  int64_t pts = frame->best_effort_timestamp;
  if (pts == AV_NOPTS_VALUE) pts = frame->pts;
  if (pts == AV_NOPTS_VALUE) return player->position_ms;
  return av_rescale_q(pts, player->video_tb, (AVRational){1, 1000});
}

static JNIEnv *play_env(FfPlayer *player) {
  if (player->play_env != NULL) return player->play_env;
  if (player->vm == NULL) return NULL;
  JNIEnv *env = NULL;
  if ((*player->vm)->GetEnv(player->vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) {
    player->play_env = env;
    return env;
  }
  if ((*player->vm)->AttachCurrentThread(player->vm, &env, NULL) != 0) return NULL;
  player->play_env = env;
  player->play_attached = 1;
  return env;
}

static void write_pcm(FfPlayer *player, const uint8_t *data, int bytes) {
  if (player->self == NULL || player->on_pcm == NULL || bytes <= 0) return;
  JNIEnv *env = play_env(player);
  if (env == NULL) return;
  jbyteArray array = (*env)->NewByteArray(env, bytes);
  if (array != NULL) {
    (*env)->SetByteArrayRegion(env, array, 0, bytes, (const jbyte *)data);
    (*env)->CallVoidMethod(env, player->self, player->on_pcm, array);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, array);
  }
}

static void reset_audio(FfPlayer *player) {
  player->audio_samples = 0;
  if (player->self == NULL || player->on_audio_reset == NULL) return;
  JNIEnv *env = play_env(player);
  if (env == NULL) return;
  (*env)->CallVoidMethod(env, player->self, player->on_audio_reset);
  if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void emit_frame(FfPlayer *player, int64_t pts_ms) {
  if (player->self == NULL || player->on_frame == NULL || player->presented == NULL) return;
  JNIEnv *env = play_env(player);
  if (env == NULL) return;
  jobject buffer = (*env)->NewDirectByteBuffer(
      env, player->presented, (jlong)player->presented_bytes);
  if (buffer != NULL) {
    (*env)->CallVoidMethod(
        env, player->self, player->on_frame, buffer,
        player->out_w, player->out_h, (jlong)pts_ms);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, buffer);
  }
}

static void release_gl(FfPlayer *player) {
  if (player->self == NULL || player->on_gl_release == NULL) return;
  JNIEnv *env = play_env(player);
  if (env == NULL) return;
  (*env)->CallVoidMethod(env, player->self, player->on_gl_release);
  if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void emit_audio(FfPlayer *player, const AVFrame *frame) {
  if (player->swr == NULL) return;
  int out_samples = swr_get_out_samples(player->swr, frame->nb_samples);
  if (out_samples < 1) return;
  uint8_t *out = NULL;
  int line = 0;
  if (av_samples_alloc(&out, &line, player->channels, out_samples, AV_SAMPLE_FMT_S16, 0) < 0) {
    return;
  }
  int converted = swr_convert(
      player->swr, &out, out_samples,
      (const uint8_t **)frame->extended_data, frame->nb_samples);
  if (converted > 0) {
    int bytes = converted * player->channels * (int)sizeof(int16_t);
    player->audio_samples += converted;
    write_pcm(player, out, bytes);
  }
  av_freep(&out);
}

static void wait_until(FfPlayer *player, int64_t media_ms) {
  pthread_mutex_lock(&player->mu);
  if (!player->clock_ready) {
    player->clock_origin_ms = media_ms;
    player->clock_origin_mono = mono_ms();
    player->clock_ready = 1;
  }
  int64_t origin_ms = player->clock_origin_ms;
  int64_t origin_mono = player->clock_origin_mono;
  pthread_mutex_unlock(&player->mu);
  int64_t due = origin_mono + (media_ms - origin_ms);
  while (mono_ms() + 2 < due) {
    pthread_mutex_lock(&player->mu);
    int stop = player->stop || player->seek_req || !player->playing;
    pthread_mutex_unlock(&player->mu);
    if (stop) return;
    struct timespec ts = {0, 4 * 1000 * 1000};
    nanosleep(&ts, NULL);
  }
}

static int decode_video_packet(FfPlayer *player, AVPacket *packet, int present, int pace) {
  if (avcodec_send_packet(player->video, packet) != 0) return 0;
  int drew = 0;
  while (avcodec_receive_frame(player->video, player->vframe) == 0) {
    int64_t ms = frame_ms(player, player->vframe);
    pthread_mutex_lock(&player->mu);
    player->position_ms = ms;
    pthread_mutex_unlock(&player->mu);
    if (pace) wait_until(player, ms);
    if (present) present_frame(player, player->vframe);
    drew = 1;
    av_frame_unref(player->vframe);
  }
  return drew;
}

static void decode_audio_packet(FfPlayer *player, AVPacket *packet) {
  if (player->audio == NULL) return;
  if (avcodec_send_packet(player->audio, packet) != 0) return;
  while (avcodec_receive_frame(player->audio, player->aframe) == 0) {
    emit_audio(player, player->aframe);
    av_frame_unref(player->aframe);
  }
}

static int take_seek(FfPlayer *player, int64_t *ms) {
  pthread_mutex_lock(&player->mu);
  int stop = player->stop;
  int pending = player->seek_req;
  if (pending) {
    *ms = player->seek_ms;
    player->seek_req = 0;
  }
  pthread_mutex_unlock(&player->mu);
  if (stop) return -1;
  return pending ? 1 : 0;
}

static void reposition(FfPlayer *player, int64_t ms) {
  int64_t target = av_rescale_q(ms, (AVRational){1, 1000}, AV_TIME_BASE_Q);
  if (avformat_seek_file(
          player->fmt, -1, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD) < 0) {
    av_seek_frame(player->fmt, -1, target, AVSEEK_FLAG_BACKWARD);
  }
  if (player->video != NULL) avcodec_flush_buffers(player->video);
  if (player->audio != NULL) avcodec_flush_buffers(player->audio);
  reset_audio(player);
  pthread_mutex_lock(&player->mu);
  player->clock_ready = 0;
  player->ended = 0;
  pthread_mutex_unlock(&player->mu);
  player->demux_ms = -1;
  player->demux_ready = 1;
}

static int target_moved(int64_t target, int64_t shown) {
  if (shown < 0) return 0;
  if (target + 80 < shown) return 1;
  if (target > shown + 2500) return 1;
  return 0;
}

static void perform_seek(FfPlayer *player, int64_t ms, int exact) {
  (void)exact;
  int64_t target = ms;
  for (int hop = 0; hop < 6; hop++) {
    int near = player->demux_ready && player->demux_ms >= 0 &&
               target + 80 >= player->demux_ms &&
               target <= player->demux_ms + 2500;
    if (!near) reposition(player, target);

    int reads = 0;
    int restart = 0;
    while (reads < 2000) {
      int pulled = take_seek(player, &target);
      if (pulled < 0) return;
      if (pulled && target_moved(target, player->demux_ms)) {
        restart = 1;
        break;
      }
      int read = av_read_frame(player->fmt, player->packet);
      if (read < 0) return;
      reads += 1;
      if (player->packet->stream_index == player->video_index &&
          avcodec_send_packet(player->video, player->packet) == 0) {
        while (avcodec_receive_frame(player->video, player->vframe) == 0) {
          int64_t pts = frame_ms(player, player->vframe);
          pthread_mutex_lock(&player->mu);
          player->position_ms = pts;
          pthread_mutex_unlock(&player->mu);
          pulled = take_seek(player, &target);
          if (pulled < 0) {
            av_frame_unref(player->vframe);
            av_packet_unref(player->packet);
            return;
          }
          if (pulled && target_moved(target, pts)) {
            av_frame_unref(player->vframe);
            av_packet_unref(player->packet);
            restart = 1;
            break;
          }
          present_frame(player, player->vframe);
          player->demux_ms = pts;
          av_frame_unref(player->vframe);
          if (pts + 40 >= target) {
            pulled = take_seek(player, &target);
            if (pulled < 0) {
              av_packet_unref(player->packet);
              return;
            }
            if (!pulled || !target_moved(target, pts)) {
              if (pulled && target > pts + 40) continue;
              av_packet_unref(player->packet);
              return;
            }
            av_packet_unref(player->packet);
            restart = 1;
            break;
          }
        }
        if (restart) break;
      }
      if (!restart) av_packet_unref(player->packet);
    }
    if (!restart) return;
  }
}

static void *play_thread(void *arg) {
  FfPlayer *player = (FfPlayer *)arg;
  for (;;) {
    pthread_mutex_lock(&player->mu);
    while (!player->stop && !player->seek_req && !player->playing) {
      pthread_cond_wait(&player->cv, &player->mu);
    }
    if (player->stop) {
      pthread_mutex_unlock(&player->mu);
      break;
    }
    int do_seek = player->seek_req;
    int64_t seek_ms = player->seek_ms;
    int exact = player->seek_exact;
    player->seek_req = 0;
    int playing = player->playing;
    pthread_mutex_unlock(&player->mu);

    if (do_seek) perform_seek(player, seek_ms, exact);
    if (!playing) continue;

    int read = av_read_frame(player->fmt, player->packet);
    if (read < 0) {
      decode_video_packet(player, NULL, 1, 1);
      pthread_mutex_lock(&player->mu);
      player->playing = 0;
      player->ended = 1;
      pthread_cond_broadcast(&player->cv);
      pthread_mutex_unlock(&player->mu);
      continue;
    }
    if (player->packet->stream_index == player->video_index) {
      decode_video_packet(player, player->packet, 1, 1);
    } else if (player->packet->stream_index == player->audio_index) {
      decode_audio_packet(player, player->packet);
    }
    av_packet_unref(player->packet);
  }
  release_gl(player);
  if (player->play_attached && player->vm != NULL) {
    (*player->vm)->DetachCurrentThread(player->vm);
  }
  player->play_env = NULL;
  player->play_attached = 0;
  return NULL;
}

static int open_decoder(AVCodecContext **out, const AVStream *stream) {
  const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
  if (codec == NULL) return -1;
  AVCodecContext *ctx = avcodec_alloc_context3(codec);
  if (ctx == NULL) return -1;
  if (avcodec_parameters_to_context(ctx, stream->codecpar) < 0) {
    avcodec_free_context(&ctx);
    return -1;
  }
  ctx->thread_count = 4;
  ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
  if (avcodec_open2(ctx, codec, NULL) < 0) {
    avcodec_free_context(&ctx);
    return -1;
  }
  *out = ctx;
  return 0;
}

static FfPlayer *player_open(const char *path) {
  FfPlayer *player = (FfPlayer *)calloc(1, sizeof(FfPlayer));
  if (player == NULL) return NULL;
  player->video_index = -1;
  player->audio_index = -1;
  player->channels = 2;
  pthread_mutex_init(&player->mu, NULL);
  pthread_cond_init(&player->cv, NULL);
  player->vframe = av_frame_alloc();
  player->aframe = av_frame_alloc();
  player->packet = av_packet_alloc();
  if (player->vframe == NULL || player->aframe == NULL || player->packet == NULL) {
    goto fail;
  }
  if (avformat_open_input(&player->fmt, path, NULL, NULL) < 0 ||
      avformat_find_stream_info(player->fmt, NULL) < 0) {
    LOGE("ffmpeg open failed %s", path);
    goto fail;
  }
  player->video_index = av_find_best_stream(
      player->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (player->video_index < 0) goto fail;
  AVStream *video = player->fmt->streams[player->video_index];
  if (open_decoder(&player->video, video) != 0) goto fail;
  player->video_tb = video->time_base;
  player->rotation = display_rotation(video);
  player->out_w = player->video->width > 0 ? player->video->width : 720;
  player->out_h = player->video->height > 0 ? player->video->height : 1280;
  if (player->rotation == 90 || player->rotation == 270) {
    int swap = player->out_w;
    player->out_w = player->out_h;
    player->out_h = swap;
  }
  if (player->fmt->duration > 0) {
    player->duration_ms = player->fmt->duration / (AV_TIME_BASE / 1000);
  }
  player->audio_index = av_find_best_stream(
      player->fmt, AVMEDIA_TYPE_AUDIO, -1, player->video_index, NULL, 0);
  if (player->audio_index >= 0) {
    AVStream *audio = player->fmt->streams[player->audio_index];
    if (open_decoder(&player->audio, audio) == 0) {
      AVChannelLayout out_layout;
      AVChannelLayout in_layout;
      memset(&in_layout, 0, sizeof(in_layout));
      av_channel_layout_default(&out_layout, 2);
      if (player->audio->ch_layout.nb_channels <= 0 ||
          av_channel_layout_copy(&in_layout, &player->audio->ch_layout) < 0) {
        av_channel_layout_default(&in_layout, 2);
      }
      player->sample_rate = player->audio->sample_rate > 0
          ? player->audio->sample_rate
          : 44100;
      if (swr_alloc_set_opts2(
              &player->swr,
              &out_layout, AV_SAMPLE_FMT_S16, player->sample_rate,
              &in_layout, player->audio->sample_fmt, player->sample_rate,
              0, NULL) < 0 ||
          player->swr == NULL || swr_init(player->swr) < 0) {
        swr_free(&player->swr);
        avcodec_free_context(&player->audio);
        player->audio_index = -1;
      }
      av_channel_layout_uninit(&in_layout);
      av_channel_layout_uninit(&out_layout);
    } else {
      player->audio_index = -1;
    }
  }
  if (pthread_create(&player->thread, NULL, play_thread, player) != 0) goto fail;
  player->thread_started = 1;
  LOGI(
      "ffmpeg player open %dx%d rot=%d audio=%d duration=%lld",
      player->out_w, player->out_h, player->rotation,
      player->audio_index >= 0, (long long)player->duration_ms);
  return player;

fail:
  if (player->thread_started) {
    pthread_mutex_lock(&player->mu);
    player->stop = 1;
    pthread_cond_broadcast(&player->cv);
    pthread_mutex_unlock(&player->mu);
    pthread_join(player->thread, NULL);
  }
  release_sws(player);
  swr_free(&player->swr);
  avcodec_free_context(&player->video);
  avcodec_free_context(&player->audio);
  avformat_close_input(&player->fmt);
  av_frame_free(&player->vframe);
  av_frame_free(&player->aframe);
  av_packet_free(&player->packet);
  pthread_mutex_destroy(&player->mu);
  pthread_cond_destroy(&player->cv);
  free(player);
  return NULL;
}

static void player_close(FfPlayer *player) {
  if (player == NULL) return;
  pthread_mutex_lock(&player->mu);
  player->stop = 1;
  player->playing = 0;
  pthread_cond_broadcast(&player->cv);
  pthread_mutex_unlock(&player->mu);
  if (player->thread_started) pthread_join(player->thread, NULL);
  if (player->window != NULL) ANativeWindow_release(player->window);
  release_sws(player);
  swr_free(&player->swr);
  avcodec_free_context(&player->video);
  avcodec_free_context(&player->audio);
  avformat_close_input(&player->fmt);
  av_frame_free(&player->vframe);
  av_frame_free(&player->aframe);
  av_packet_free(&player->packet);
  pthread_mutex_destroy(&player->mu);
  pthread_cond_destroy(&player->cv);
  free(player);
}

static void request_seek(FfPlayer *player, int64_t ms, int exact, int wait) {
  pthread_mutex_lock(&player->mu);
  int seen = player->present_gen;
  player->seek_ms = ms < 0 ? 0 : ms;
  player->seek_exact = exact;
  player->seek_req = 1;
  player->ended = 0;
  pthread_cond_broadcast(&player->cv);
  if (wait) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 2;
    while (!player->stop && player->present_gen == seen) {
      if (pthread_cond_timedwait(&player->cv, &player->mu, &ts) == ETIMEDOUT) break;
    }
  }
  pthread_mutex_unlock(&player->mu);
}

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeOpen(
    JNIEnv *env, jobject thiz, jstring path) {
  const char *utf = (*env)->GetStringUTFChars(env, path, NULL);
  if (utf == NULL) return 0;
  FfPlayer *player = player_open(utf);
  (*env)->ReleaseStringUTFChars(env, path, utf);
  if (player == NULL) return 0;
  (*env)->GetJavaVM(env, &player->vm);
  player->self = (*env)->NewGlobalRef(env, thiz);
  jclass cls = (*env)->GetObjectClass(env, thiz);
  player->on_pcm = (*env)->GetMethodID(env, cls, "onPcm", "([B)V");
  player->on_audio_reset = (*env)->GetMethodID(env, cls, "onAudioReset", "()V");
  player->on_frame = (*env)->GetMethodID(
      env, cls, "onVideoFrame", "(Ljava/nio/ByteBuffer;IIJ)V");
  player->on_gl_release = (*env)->GetMethodID(env, cls, "onGlRelease", "()V");
  return (jlong)player;
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeClose(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  jobject self = player->self;
  player_close(player);
  player->self = NULL;
  if (self != NULL) (*env)->DeleteGlobalRef(env, self);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeSetSurface(
    JNIEnv *env, jobject thiz, jlong handle, jobject surface, jint width, jint height) {
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  ANativeWindow *window = surface == NULL
      ? NULL
      : ANativeWindow_fromSurface(env, surface);
  pthread_mutex_lock(&player->mu);
  if (player->window != NULL) ANativeWindow_release(player->window);
  player->window = window;
  if (width > 1 && height > 1) {
    player->out_w = width;
    player->out_h = height;
  }
  pthread_mutex_unlock(&player->mu);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeSeek(
    JNIEnv *env, jobject thiz, jlong handle, jlong ms) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  request_seek(player, (int64_t)ms, 0, 0);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeSeekExact(
    JNIEnv *env, jobject thiz, jlong handle, jlong ms, jboolean wait) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  request_seek(player, (int64_t)ms, 1, wait == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativePlay(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  pthread_mutex_lock(&player->mu);
  player->playing = 1;
  player->ended = 0;
  player->clock_ready = 0;
  pthread_cond_broadcast(&player->cv);
  pthread_mutex_unlock(&player->mu);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativePause(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return;
  pthread_mutex_lock(&player->mu);
  player->playing = 0;
  pthread_cond_broadcast(&player->cv);
  pthread_mutex_unlock(&player->mu);
}

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativePosition(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return 0;
  pthread_mutex_lock(&player->mu);
  jlong ms = (jlong)player->position_ms;
  pthread_mutex_unlock(&player->mu);
  return ms;
}

JNIEXPORT jboolean JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeEnded(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL) return JNI_FALSE;
  pthread_mutex_lock(&player->mu);
  jboolean ended = player->ended ? JNI_TRUE : JNI_FALSE;
  pthread_mutex_unlock(&player->mu);
  return ended;
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegPlayer_nativeSampleRate(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  FfPlayer *player = (FfPlayer *)handle;
  if (player == NULL || player->audio == NULL) return 0;
  return player->sample_rate;
}

typedef struct FfGrab {
  AVFormatContext *fmt;
  AVCodecContext *video;
  int video_index;
  AVRational video_tb;
  int rotation;
  SwsContext *sws;
  int sws_w;
  int sws_h;
  int sws_src_w;
  int sws_src_h;
  int sws_fmt;
  uint8_t *scaled;
  int scaled_stride;
  AVFrame *frame;
  AVPacket *packet;
} FfGrab;

static void grab_close(FfGrab *grab) {
  if (grab == NULL) return;
  sws_freeContext(grab->sws);
  free(grab->scaled);
  avcodec_free_context(&grab->video);
  avformat_close_input(&grab->fmt);
  av_frame_free(&grab->frame);
  av_packet_free(&grab->packet);
  free(grab);
}

static void copy_rotated(
    const uint8_t *src, int src_stride, int sw, int sh, int rot,
    uint8_t *dst, int dw, int dh) {
  if (rot == 0) {
    int copy_w = sw < dw ? sw : dw;
    int copy_h = sh < dh ? sh : dh;
    for (int y = 0; y < copy_h; y++) {
      memcpy(
          dst + (size_t)y * (size_t)dw * 4,
          src + (size_t)y * (size_t)src_stride,
          (size_t)copy_w * 4);
    }
    return;
  }
  for (int sy = 0; sy < sh; sy++) {
    for (int sx = 0; sx < sw; sx++) {
      int dx = sx;
      int dy = sy;
      if (rot == 90) {
        dx = sh - 1 - sy;
        dy = sx;
      } else if (rot == 180) {
        dx = sw - 1 - sx;
        dy = sh - 1 - sy;
      } else if (rot == 270) {
        dx = sy;
        dy = sw - 1 - sx;
      }
      if (dx < 0 || dy < 0 || dx >= dw || dy >= dh) continue;
      put_pixel(
          dst, dw, dx, dy,
          src + (size_t)sy * (size_t)src_stride + (size_t)sx * 4);
    }
  }
}

static int grab_fit(const AVFrame *frame, int rot, int max_side, int *out_w, int *out_h) {
  int sw = frame->width;
  int sh = frame->height;
  int upright_w = (rot == 90 || rot == 270) ? sh : sw;
  int upright_h = (rot == 90 || rot == 270) ? sw : sh;
  if (upright_w < 2) upright_w = 2;
  if (upright_h < 2) upright_h = 2;
  int long_side = upright_w > upright_h ? upright_w : upright_h;
  if (max_side > 0 && long_side > max_side) {
    upright_w = upright_w * max_side / long_side;
    upright_h = upright_h * max_side / long_side;
  }
  upright_w &= ~1;
  upright_h &= ~1;
  if (upright_w < 2) upright_w = 2;
  if (upright_h < 2) upright_h = 2;
  *out_w = upright_w;
  *out_h = upright_h;
  return 0;
}

static uint8_t *grab_rgba(FfGrab *grab, const AVFrame *frame, int max_side, int *out_w, int *out_h) {
  int dw = 0;
  int dh = 0;
  grab_fit(frame, grab->rotation, max_side, &dw, &dh);
  int sws_w = (grab->rotation == 90 || grab->rotation == 270) ? dh : dw;
  int sws_h = (grab->rotation == 90 || grab->rotation == 270) ? dw : dh;
  if (grab->sws == NULL || grab->sws_src_w != frame->width || grab->sws_src_h != frame->height ||
      grab->sws_fmt != frame->format || grab->sws_w != sws_w || grab->sws_h != sws_h) {
    sws_freeContext(grab->sws);
    free(grab->scaled);
    grab->scaled = NULL;
    grab->sws = sws_getContext(
        frame->width, frame->height, (enum AVPixelFormat)frame->format,
        sws_w, sws_h, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, NULL, NULL, NULL);
    if (grab->sws == NULL) return NULL;
    grab->sws_src_w = frame->width;
    grab->sws_src_h = frame->height;
    grab->sws_fmt = frame->format;
    grab->sws_w = sws_w;
    grab->sws_h = sws_h;
    grab->scaled_stride = sws_w * 4;
    grab->scaled = (uint8_t *)malloc((size_t)grab->scaled_stride * (size_t)sws_h);
    if (grab->scaled == NULL) return NULL;
  }
  uint8_t *planes[4] = {grab->scaled, NULL, NULL, NULL};
  int strides[4] = {grab->scaled_stride, 0, 0, 0};
  sws_scale(
      grab->sws, (const uint8_t *const *)frame->data, frame->linesize,
      0, frame->height, planes, strides);
  uint8_t *rgba = (uint8_t *)malloc((size_t)dw * (size_t)dh * 4);
  if (rgba == NULL) return NULL;
  memset(rgba, 0, (size_t)dw * (size_t)dh * 4);
  copy_rotated(grab->scaled, grab->scaled_stride, sws_w, sws_h, grab->rotation, rgba, dw, dh);
  *out_w = dw;
  *out_h = dh;
  return rgba;
}

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegStill_nativeOpen(
    JNIEnv *env, jobject thiz, jstring path) {
  (void)thiz;
  const char *utf = (*env)->GetStringUTFChars(env, path, NULL);
  if (utf == NULL) return 0;
  FfGrab *grab = (FfGrab *)calloc(1, sizeof(FfGrab));
  if (grab == NULL) {
    (*env)->ReleaseStringUTFChars(env, path, utf);
    return 0;
  }
  grab->video_index = -1;
  if (avformat_open_input(&grab->fmt, utf, NULL, NULL) < 0 ||
      avformat_find_stream_info(grab->fmt, NULL) < 0) {
    (*env)->ReleaseStringUTFChars(env, path, utf);
    grab_close(grab);
    return 0;
  }
  (*env)->ReleaseStringUTFChars(env, path, utf);
  grab->video_index = av_find_best_stream(grab->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (grab->video_index < 0) {
    grab_close(grab);
    return 0;
  }
  AVStream *video = grab->fmt->streams[grab->video_index];
  grab->video_tb = video->time_base;
  grab->rotation = display_rotation(video);
  if (open_decoder(&grab->video, video) != 0) {
    grab_close(grab);
    return 0;
  }
  grab->frame = av_frame_alloc();
  grab->packet = av_packet_alloc();
  if (grab->frame == NULL || grab->packet == NULL) {
    grab_close(grab);
    return 0;
  }
  return (jlong)grab;
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegStill_nativeClose(
    JNIEnv *env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  grab_close((FfGrab *)handle);
}

JNIEXPORT jbyteArray JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegStill_nativeFrame(
    JNIEnv *env, jobject thiz, jlong handle, jlong time_ms, jint max_side, jintArray wh) {
  (void)thiz;
  FfGrab *grab = (FfGrab *)handle;
  if (grab == NULL || grab->video == NULL) return NULL;
  int64_t target = av_rescale_q(time_ms, (AVRational){1, 1000}, grab->video_tb);
  if (av_seek_frame(grab->fmt, grab->video_index, target, AVSEEK_FLAG_BACKWARD) < 0) {
    avformat_seek_file(grab->fmt, grab->video_index, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD);
  }
  avcodec_flush_buffers(grab->video);
  uint8_t *rgba = NULL;
  int dw = 0;
  int dh = 0;
  int reads = 0;
  while (rgba == NULL && reads < 240) {
    if (av_read_frame(grab->fmt, grab->packet) < 0) break;
    reads += 1;
    if (grab->packet->stream_index == grab->video_index &&
        avcodec_send_packet(grab->video, grab->packet) == 0) {
      while (avcodec_receive_frame(grab->video, grab->frame) == 0) {
        int64_t pts = grab->frame->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = grab->frame->pts;
        int64_t ms = pts == AV_NOPTS_VALUE
            ? time_ms
            : av_rescale_q(pts, grab->video_tb, (AVRational){1, 1000});
        int show = ms + 40 >= time_ms;
        if (show) rgba = grab_rgba(grab, grab->frame, max_side, &dw, &dh);
        av_frame_unref(grab->frame);
        if (rgba != NULL) break;
      }
    }
    av_packet_unref(grab->packet);
  }
  if (rgba == NULL) return NULL;
  jsize bytes = (jsize)dw * dh * 4;
  jbyteArray array = (*env)->NewByteArray(env, bytes);
  if (array != NULL) {
    (*env)->SetByteArrayRegion(env, array, 0, bytes, (const jbyte *)rgba);
    jint size[2] = {dw, dh};
    (*env)->SetIntArrayRegion(env, wh, 0, 2, size);
  }
  free(rgba);
  return array;
}

static void grab_seek(FfGrab *grab, int64_t time_ms) {
  int64_t target = av_rescale_q(time_ms, (AVRational){1, 1000}, grab->video_tb);
  if (av_seek_frame(grab->fmt, grab->video_index, target, AVSEEK_FLAG_BACKWARD) < 0) {
    avformat_seek_file(
        grab->fmt, grab->video_index, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD);
  }
  avcodec_flush_buffers(grab->video);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegStill_nativeSeek(
    JNIEnv *env, jobject thiz, jlong handle, jlong time_ms) {
  (void)env;
  (void)thiz;
  FfGrab *grab = (FfGrab *)handle;
  if (grab == NULL || grab->video == NULL) return;
  grab_seek(grab, time_ms);
}

JNIEXPORT jbyteArray JNICALL
Java_com_smart_aveditor_nativevideo_FfmpegStill_nativePull(
    JNIEnv *env, jobject thiz, jlong handle, jint max_side, jintArray info) {
  (void)thiz;
  FfGrab *grab = (FfGrab *)handle;
  if (grab == NULL || grab->video == NULL) return NULL;
  int reads = 0;
  while (reads < 64) {
    if (av_read_frame(grab->fmt, grab->packet) < 0) return NULL;
    reads += 1;
    int got = 0;
    uint8_t *rgba = NULL;
    int dw = 0;
    int dh = 0;
    int64_t ms = 0;
    if (grab->packet->stream_index == grab->video_index &&
        avcodec_send_packet(grab->video, grab->packet) == 0) {
      if (avcodec_receive_frame(grab->video, grab->frame) == 0) {
        int64_t pts = grab->frame->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = grab->frame->pts;
        ms = pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(pts, grab->video_tb, (AVRational){1, 1000});
        rgba = grab_rgba(grab, grab->frame, max_side, &dw, &dh);
        av_frame_unref(grab->frame);
        got = rgba != NULL;
      }
    }
    av_packet_unref(grab->packet);
    if (!got) continue;
    jsize bytes = (jsize)dw * dh * 4;
    jbyteArray array = (*env)->NewByteArray(env, bytes);
    if (array != NULL) {
      (*env)->SetByteArrayRegion(env, array, 0, bytes, (const jbyte *)rgba);
      jint packed[3] = {dw, dh, (jint)ms};
      (*env)->SetIntArrayRegion(env, info, 0, 3, packed);
    }
    free(rgba);
    return array;
  }
  return NULL;
}
