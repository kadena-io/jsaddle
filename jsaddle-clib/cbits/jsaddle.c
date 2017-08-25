#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include <unistd.h>
#include <jni.h>
#include <stdio.h>
#include <android/log.h>
#include "HsFFI.h"
#include "Rts.h"

#include "focus.h"

extern StgClosure ZCMain_main_closure;
static native_callbacks* hsCallbacks = NULL;
static JavaVM* jvm = NULL;
static jobject javaCallback = NULL;
static jmethodID evaluateJSCallback = NULL;
static jmethodID mainStartedCallback = NULL;
static app_callbacks hsAppCallbacks = { NULL }; //TODO: Expose this

static int pfd[2];
static pthread_t thr;
static const char *tag = "";

static void *thread_func(void*);

int start_logger(const char *app_name) {
    tag = app_name;

    setvbuf(stdout, 0, _IOLBF, 0);
    setvbuf(stderr, 0, _IOLBF, 0);

    /* create the pipe and redirect stdout and stderr */
    pipe(pfd);
    dup2(pfd[1], 1);
    dup2(pfd[1], 2);

    /* spawn the logging thread */
    if(pthread_create(&thr, 0, thread_func, 0) == -1) {
        __android_log_write(ANDROID_LOG_DEBUG, tag, "Could not start logger");
        return -1;
    }
    pthread_detach(thr);
    return 0;
}

void *thread_func(void* unused)
{
    ssize_t rdsz;
    char buf[256];

    __android_log_write(ANDROID_LOG_DEBUG, tag, "Logger running");
    while((rdsz = read(pfd[0], buf, sizeof buf - 1)) > 0) {
        if(buf[rdsz - 1] == '\n') --rdsz;
        buf[rdsz] = 0;  /* add null-terminator */
        __android_log_write(ANDROID_LOG_DEBUG, tag, buf);
    }
    return 0;
}

JNIEXPORT jint JNICALL JNI_OnLoad ( JavaVM *vm, void *reserved ) {
  jvm = vm;

  start_logger("JSADDLEC"); //TODO: Use the app name

  return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL Java_systems_obsidian_JSaddleShim_deinit ( JNIEnv *env, jobject thisObj ) {
  hs_exit();
}

JNIEXPORT void JNICALL Java_systems_obsidian_LocalFirebaseInstanceIDService_handleDeviceToken ( JNIEnv *env, jobject thisObj, jstring token ) {
  if(hsAppCallbacks.firebaseInstanceIdService_sendRegistrationToServer) {
    const char *cstring_token = (*env)->GetStringUTFChars(env, token, 0);
    hsAppCallbacks.firebaseInstanceIdService_sendRegistrationToServer(cstring_token);
    (*env)->ReleaseStringUTFChars(env, token, cstring_token);
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_JSaddleShim_processMessage (JNIEnv *env, jobject thisObj, jstring msg) {
  const char *msg_str = (*env)->GetStringUTFChars(env, msg, NULL);
  (*(hsCallbacks->jsaddleResult))(msg_str);
  (*env)->ReleaseStringUTFChars(env, msg, msg_str);
  return;
}

JNIEXPORT jstring JNICALL Java_systems_obsidian_JSaddleShim_processSyncMessage (JNIEnv *env, jobject thisObj, jstring msg) {
  const char *msg_str = (*env)->GetStringUTFChars(env, msg, NULL);
  char *next_str = (*(hsCallbacks->jsaddleSyncResult))(msg_str);
  jstring next_jstr = (*env)->NewStringUTF(env,next_str);
  free(next_str);
  (*env)->ReleaseStringUTFChars(env, msg, msg_str);
  return next_jstr;
}

JNIEXPORT void JNICALL Java_systems_obsidian_JSaddleShim_injectJavascript (JNIEnv *env) {
  jstring js_str = (*env)->NewStringUTF(env, hsCallbacks->jsaddleJsData);
  (*env)->CallVoidMethod(env, javaCallback, evaluateJSCallback, js_str);
  (*env)->DeleteLocalRef(env, js_str);
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_JSaddleShim_init (JNIEnv *env, jobject jsaddleObj) {
  javaCallback = (*env)->NewGlobalRef(env, jsaddleObj);
  jclass cls = (*env)->GetObjectClass(env, javaCallback);
  evaluateJSCallback = (*env)->GetMethodID(env, cls, "evaluateJavascript", "(Ljava/lang/String;)V");
  mainStartedCallback = (*env)->GetMethodID(env, cls, "mainStarted", "()V");

  static int argc = 5;
  static char *argv[] = {"jsaddle", "+RTS", "-N2", "-I0", "-RTS"};

  RtsConfig rts_opts = defaultRtsConfig;
  rts_opts.rts_opts_enabled = RtsOptsAll;
  hs_main(argc, argv, &ZCMain_main_closure, rts_opts);

  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_JSaddleShim_startProcessing (JNIEnv *env) {
  (*(hsCallbacks->jsaddleStart))();
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnCreate (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onCreate) {
    hsAppCallbacks.mainActivity_onCreate();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnStart (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onStart) {
    hsAppCallbacks.mainActivity_onStart();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnResume (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onResume) {
    hsAppCallbacks.mainActivity_onResume();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnPause (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onPause) {
    hsAppCallbacks.mainActivity_onPause();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnStop (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onStop) {
    hsAppCallbacks.mainActivity_onStop();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnDestroy (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onDestroy) {
    hsAppCallbacks.mainActivity_onDestroy();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnRestart (JNIEnv *env) {
  if(hsAppCallbacks.mainActivity_onRestart) {
    hsAppCallbacks.mainActivity_onRestart();
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_AppCallbacksShim_mainActivityOnNewIntent ( JNIEnv *env, jobject thisObj, jstring intent, jstring intentdata ) {
  if(hsAppCallbacks.mainActivity_onNewIntent) {
    const char *cstring_intent = (*env)->GetStringUTFChars(env, intent, 0);
    const char *cstring_intentdata = (*env)->GetStringUTFChars(env, intentdata, 0);
    hsAppCallbacks.mainActivity_onNewIntent(cstring_intent, cstring_intentdata);
    (*env)->ReleaseStringUTFChars(env, intent, cstring_intent);
    (*env)->ReleaseStringUTFChars(env, intentdata, cstring_intentdata);
  }
  return;
}

JNIEXPORT void JNICALL Java_systems_obsidian_LocalFirebaseMessagingService_handleNotification ( JNIEnv *env, jobject thisObj, jstring intent, jstring notificationdata) {
  if(hsAppCallbacks.mainActivity_onNewIntent) {
    const char *cstring_intent = (*env)->GetStringUTFChars(env, intent, 0);
    const char *cstring_notificationdata = (*env)->GetStringUTFChars(env, notificationdata, 0);
    hsAppCallbacks.mainActivity_onNewIntent(cstring_intent, cstring_notificationdata);
    (*env)->ReleaseStringUTFChars(env, intent, cstring_intent);
    (*env)->ReleaseStringUTFChars(env, notificationdata, cstring_notificationdata);
  }
  return;
}


void evaluateJavascript (const char* js) {
  JNIEnv *env;
  jint attachResult = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
  assert (attachResult == JNI_OK);
  jstring js_str = (*env)->NewStringUTF(env, js);
  (*env)->CallVoidMethod(env, javaCallback, evaluateJSCallback, js_str);
  (*env)->DeleteLocalRef(env, js_str);
  //  jint detachResult = (*jvm) -> DetachCurrentThread(jvm); //TODO: I think this is unnecessary
  //  assert (detachResult == JNI_OK);
  return;
}

void mainStarted(native_callbacks* newNativeCallbacks) {
  hsCallbacks = newNativeCallbacks;

  JNIEnv *env;
  jint attachResult = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
  assert(attachResult == JNI_OK);
  (*env)->CallVoidMethod(env, javaCallback, mainStartedCallback);
}
