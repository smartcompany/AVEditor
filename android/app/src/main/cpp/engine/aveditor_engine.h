#pragma once

#include <jni.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque engine handle. */
typedef struct AveditorEngine AveditorEngine;

AveditorEngine *aveditor_engine_create(JNIEnv *env, jobject j_engine);
void aveditor_engine_release(AveditorEngine *engine);

/** JSON plan from Kotlin (sourcePath, totalMs, width, height, pieces[], blends[]). */
int aveditor_engine_set_plan(AveditorEngine *engine, const char *json_utf8);

/** Flutter output Surface (may be null to clear). */
int aveditor_engine_set_output_surface(JNIEnv *env, AveditorEngine *engine, jobject surface);

/** Decoder output Surfaces (slot 0 / 1). Created in Kotlin via SurfaceTexture. */
int aveditor_engine_set_decoder_surface(
    JNIEnv *env, AveditorEngine *engine, int slot, jobject surface);

void aveditor_engine_play(AveditorEngine *engine);
void aveditor_engine_pause(AveditorEngine *engine);
void aveditor_engine_seek(AveditorEngine *engine, int64_t position_ms);
int64_t aveditor_engine_position_ms(AveditorEngine *engine);
int64_t aveditor_engine_duration_ms(AveditorEngine *engine);
int aveditor_engine_is_playing(AveditorEngine *engine);

/**
 * Drive demux/decode. Call from a dedicated thread ~60Hz (or faster).
 * Returns 1 if a new video frame was rendered to a decoder surface.
 */
int aveditor_engine_pump(AveditorEngine *engine);

/** Which decoder slots should be active at current position (out_a/out_b = 0/1). */
void aveditor_engine_active_slots(
    AveditorEngine *engine, int *out_a, int *out_b, float *blend_t, char *effect, int effect_cap);

/** Offline export to [path]. Blocks; reports progress via JNI callback on j_engine. */
int aveditor_engine_export(AveditorEngine *engine, const char *path_utf8, int width, int height);
void aveditor_engine_cancel_export(AveditorEngine *engine);

#ifdef __cplusplus
}
#endif
