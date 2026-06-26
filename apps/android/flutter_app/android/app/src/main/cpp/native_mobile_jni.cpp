#include <jni.h>

#include "plushpal_mobile.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {

std::string utf8(JNIEnv *env, jstring value) {
  const char *characters = env->GetStringUTFChars(value, nullptr);
  if (characters == nullptr) return {};
  std::string result(characters);
  env->ReleaseStringUTFChars(value, characters);
  return result;
}

jstring java_utf8_string(JNIEnv *env, const std::vector<uint8_t> &bytes) {
  jbyteArray array = env->NewByteArray(static_cast<jsize>(bytes.size()));
  if (array == nullptr) return nullptr;
  env->SetByteArrayRegion(array, 0, static_cast<jsize>(bytes.size()),
                          reinterpret_cast<const jbyte *>(bytes.data()));
  jclass string_class = env->FindClass("java/lang/String");
  jmethodID constructor =
      env->GetMethodID(string_class, "<init>", "([BLjava/lang/String;)V");
  jstring charset = env->NewStringUTF("UTF-8");
  return static_cast<jstring>(
      env->NewObject(string_class, constructor, array, charset));
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_plushpal_app_MainActivity_nativeCreateEngine(JNIEnv *env,
                                                       jobject,
                                                       jstring model_path) {
  const std::string path = utf8(env, model_path);
  pp_mobile_engine_t *engine = nullptr;
  if (pp_mobile_engine_create(PP_MOBILE_ABI_VERSION,
                              reinterpret_cast<const uint8_t *>(path.data()),
                              path.size(), &engine) != PP_MOBILE_OK) {
    return 0;
  }
  return reinterpret_cast<jlong>(engine);
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_plushpal_app_MainActivity_nativeGenerateLocal(
    JNIEnv *env, jobject, jlong engine_value, jint age_band, jstring alias_value,
    jstring text_value, jstring guidance_value) {
  auto *engine = reinterpret_cast<pp_mobile_engine_t *>(engine_value);
  const std::string alias = utf8(env, alias_value);
  const std::string text = utf8(env, text_value);
  const std::string guidance = utf8(env, guidance_value);
  size_t required = 0;
  bool suggest_adult = false;
  const auto first = pp_mobile_generate_local(
      engine, static_cast<uint8_t>(age_band),
      reinterpret_cast<const uint8_t *>(alias.data()), alias.size(),
      reinterpret_cast<const uint8_t *>(text.data()), text.size(),
      reinterpret_cast<const uint8_t *>(guidance.data()), guidance.size(), nullptr, 0,
      &required, &suggest_adult);
  if (first != PP_MOBILE_BUFFER_TOO_SMALL || required == 0 || required > 8192) {
    return nullptr;
  }
  std::vector<uint8_t> output(required);
  if (pp_mobile_generate_local(
          engine, static_cast<uint8_t>(age_band),
          reinterpret_cast<const uint8_t *>(alias.data()), alias.size(),
          reinterpret_cast<const uint8_t *>(text.data()), text.size(),
          reinterpret_cast<const uint8_t *>(guidance.data()), guidance.size(),
          output.data(), output.size(), &required,
          &suggest_adult) != PP_MOBILE_OK) {
    return nullptr;
  }
  jclass object_class = env->FindClass("java/lang/Object");
  jobjectArray result = env->NewObjectArray(2, object_class, nullptr);
  env->SetObjectArrayElement(result, 0, java_utf8_string(env, output));
  jclass boolean_class = env->FindClass("java/lang/Boolean");
  jmethodID value_of =
      env->GetStaticMethodID(boolean_class, "valueOf", "(Z)Ljava/lang/Boolean;");
  jobject boxed = env->CallStaticObjectMethod(boolean_class, value_of,
                                               suggest_adult ? JNI_TRUE : JNI_FALSE);
  env->SetObjectArrayElement(result, 1, boxed);
  return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_plushpal_app_MainActivity_nativeCancel(JNIEnv *, jobject,
                                                 jlong engine_value) {
  return pp_mobile_cancel(
             reinterpret_cast<pp_mobile_engine_t *>(engine_value)) == PP_MOBILE_OK
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_plushpal_app_MainActivity_nativeClearSession(JNIEnv *, jobject,
                                                       jlong engine_value) {
  return pp_mobile_clear_session(
             reinterpret_cast<pp_mobile_engine_t *>(engine_value)) == PP_MOBILE_OK
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_plushpal_app_MainActivity_nativeInstallBundledModel(
    JNIEnv *env, jobject, jstring destination_directory) {
  const std::string directory = utf8(env, destination_directory);
  return static_cast<jint>(pp_mobile_install_bundled_model(
      reinterpret_cast<const uint8_t *>(directory.data()), directory.size()));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_plushpal_app_MainActivity_nativeVerifyBundledModel(
    JNIEnv *env, jobject, jstring model_path) {
  const std::string path = utf8(env, model_path);
  return pp_mobile_verify_bundled_model(
             reinterpret_cast<const uint8_t *>(path.data()), path.size()) ==
                 PP_MOBILE_OK
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_plushpal_app_MainActivity_nativeCancelModelInstall(JNIEnv *, jobject) {
  pp_mobile_cancel_model_install();
}

extern "C" JNIEXPORT void JNICALL
Java_com_plushpal_app_MainActivity_nativeDestroy(JNIEnv *, jobject,
                                                  jlong engine_value) {
  pp_mobile_engine_destroy(reinterpret_cast<pp_mobile_engine_t *>(engine_value));
}
