#include "aveditor_engine.h"

#include <jni.h>

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeCreate(JNIEnv *env, jobject thiz) {
  return reinterpret_cast<jlong>(aveditor_engine_create(env, thiz));
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeRelease(
    JNIEnv *, jobject, jlong handle) {
  aveditor_engine_release(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeSetPlan(
    JNIEnv *env, jobject, jlong handle, jstring json) {
  if (!json) return -1;
  const char *utf = env->GetStringUTFChars(json, nullptr);
  const int rc = aveditor_engine_set_plan(reinterpret_cast<AveditorEngine *>(handle), utf);
  env->ReleaseStringUTFChars(json, utf);
  return rc;
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeSetOutputSurface(
    JNIEnv *env, jobject, jlong handle, jobject surface) {
  return aveditor_engine_set_output_surface(
      env, reinterpret_cast<AveditorEngine *>(handle), surface);
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeSetDecoderSurface(
    JNIEnv *env, jobject, jlong handle, jint slot, jobject surface) {
  return aveditor_engine_set_decoder_surface(
      env, reinterpret_cast<AveditorEngine *>(handle), slot, surface);
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativePlay(
    JNIEnv *, jobject, jlong handle) {
  aveditor_engine_play(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativePause(
    JNIEnv *, jobject, jlong handle) {
  aveditor_engine_pause(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeSeek(
    JNIEnv *, jobject, jlong handle, jlong ms) {
  aveditor_engine_seek(reinterpret_cast<AveditorEngine *>(handle), ms);
}

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativePositionMs(
    JNIEnv *, jobject, jlong handle) {
  return aveditor_engine_position_ms(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT jlong JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeDurationMs(
    JNIEnv *, jobject, jlong handle) {
  return aveditor_engine_duration_ms(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT jboolean JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeIsPlaying(
    JNIEnv *, jobject, jlong handle) {
  return aveditor_engine_is_playing(reinterpret_cast<AveditorEngine *>(handle)) ? JNI_TRUE
                                                                                : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativePump(
    JNIEnv *, jobject, jlong handle) {
  return aveditor_engine_pump(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT void JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeCancelExport(
    JNIEnv *, jobject, jlong handle) {
  aveditor_engine_cancel_export(reinterpret_cast<AveditorEngine *>(handle));
}

JNIEXPORT jint JNICALL
Java_com_smart_aveditor_nativevideo_EngineNative_nativeExport(
    JNIEnv *env, jobject, jlong handle, jstring path, jint width, jint height) {
  if (!path) return -1;
  const char *utf = env->GetStringUTFChars(path, nullptr);
  const int rc =
      aveditor_engine_export(reinterpret_cast<AveditorEngine *>(handle), utf, width, height);
  env->ReleaseStringUTFChars(path, utf);
  return rc;
}

}  // extern "C"
