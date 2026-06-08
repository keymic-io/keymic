#include "SherpaBridge.h"
#include "c-api.h"          // sherpa v1.13.2 真实头 → struct 布局编译器精确管理
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef const SherpaOnnxOfflineRecognizer *(*Fn_CreateRec)(const SherpaOnnxOfflineRecognizerConfig *);
typedef const SherpaOnnxOfflineStream *(*Fn_CreateStream)(const SherpaOnnxOfflineRecognizer *);
typedef void (*Fn_Accept)(const SherpaOnnxOfflineStream *, int32_t, const float *, int32_t);
typedef void (*Fn_Decode)(const SherpaOnnxOfflineRecognizer *, const SherpaOnnxOfflineStream *);
typedef const SherpaOnnxOfflineRecognizerResult *(*Fn_GetResult)(const SherpaOnnxOfflineStream *);
typedef void (*Fn_DestroyResult)(const SherpaOnnxOfflineRecognizerResult *);
typedef void (*Fn_DestroyStream)(const SherpaOnnxOfflineStream *);
typedef void (*Fn_DestroyRec)(const SherpaOnnxOfflineRecognizer *);

static Fn_CreateRec     g_createRec;
static Fn_CreateStream  g_createStream;
static Fn_Accept        g_accept;
static Fn_Decode        g_decode;
static Fn_GetResult     g_getResult;
static Fn_DestroyResult g_destroyRes;
static Fn_DestroyStream g_destroyStr;
static Fn_DestroyRec    g_destroyRec;
static int              g_loaded = 0;

int sherpa_load(const char *onnx_dir, char *err, int err_cap) {
    if (g_loaded) return 0;
    char onnxPath[2048], sherpaPath[2048];
    // 版本化名:sherpa c-api 的 @rpath 依赖串(@loader_path 解析同目录)。
    snprintf(onnxPath, sizeof(onnxPath), "%s/libonnxruntime.1.24.4.dylib", onnx_dir);
    snprintf(sherpaPath, sizeof(sherpaPath), "%s/libsherpa-onnx-c-api.dylib", onnx_dir);

    void *honnx = dlopen(onnxPath, RTLD_NOW | RTLD_GLOBAL);
    if (!honnx) { snprintf(err, err_cap, "dlopen onnxruntime FAIL: %s", dlerror()); return 1; }
    void *hsherpa = dlopen(sherpaPath, RTLD_NOW | RTLD_GLOBAL);
    if (!hsherpa) { snprintf(err, err_cap, "dlopen sherpa FAIL: %s", dlerror()); return 2; }

    g_createRec    = (Fn_CreateRec)dlsym(hsherpa, "SherpaOnnxCreateOfflineRecognizer");
    g_createStream = (Fn_CreateStream)dlsym(hsherpa, "SherpaOnnxCreateOfflineStream");
    g_accept       = (Fn_Accept)dlsym(hsherpa, "SherpaOnnxAcceptWaveformOffline");
    g_decode       = (Fn_Decode)dlsym(hsherpa, "SherpaOnnxDecodeOfflineStream");
    g_getResult    = (Fn_GetResult)dlsym(hsherpa, "SherpaOnnxGetOfflineStreamResult");
    g_destroyRes   = (Fn_DestroyResult)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizerResult");
    g_destroyStr   = (Fn_DestroyStream)dlsym(hsherpa, "SherpaOnnxDestroyOfflineStream");
    g_destroyRec   = (Fn_DestroyRec)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizer");
    if (!g_createRec || !g_createStream || !g_accept || !g_decode || !g_getResult ||
        !g_destroyRes || !g_destroyStr || !g_destroyRec) {
        snprintf(err, err_cap, "dlsym FAIL: one or more symbols null"); return 3;
    }
    g_loaded = 1;
    return 0;
}

void *sherpa_create_funasr(const char *encoder_adaptor, const char *llm,
                           const char *embedding, const char *tokenizer_dir,
                           char *err, int err_cap) {
    if (!g_loaded) { snprintf(err, err_cap, "sherpa_load not called"); return NULL; }
    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    // Fun-ASR-Nano AR:funasr_nano config(4 文件;tokenizer 为 Qwen3-0.6B 目录)。
    config.model_config.funasr_nano.encoder_adaptor = encoder_adaptor;
    config.model_config.funasr_nano.llm             = llm;
    config.model_config.funasr_nano.embedding       = embedding;
    config.model_config.funasr_nano.tokenizer       = tokenizer_dir;
    config.model_config.funasr_nano.max_new_tokens  = 200;
    config.model_config.funasr_nano.temperature     = 0.0f;   // 贪心确定性
    config.model_config.funasr_nano.top_p           = 1.0f;
    config.model_config.funasr_nano.seed            = 42;
    config.model_config.funasr_nano.language        = "auto";
    config.model_config.funasr_nano.itn             = 1;
    config.model_config.num_threads = 2;
    config.model_config.provider    = "cpu";
    config.model_config.debug       = 0;
    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *rec = g_createRec(&config);
    if (!rec) { snprintf(err, err_cap, "CreateOfflineRecognizer NULL"); return NULL; }
    return (void *)rec;
}

int sherpa_decode(void *recognizer, const float *samples, int n, int sample_rate,
                  char *out, int out_cap) {
    if (!recognizer) { snprintf(out, out_cap, "nil recognizer"); return 1; }
    const SherpaOnnxOfflineRecognizer *rec = (const SherpaOnnxOfflineRecognizer *)recognizer;
    const SherpaOnnxOfflineStream *stream = g_createStream(rec);
    if (!stream) { snprintf(out, out_cap, "CreateOfflineStream NULL"); return 2; }
    g_accept(stream, sample_rate, samples, n);
    g_decode(rec, stream);
    const SherpaOnnxOfflineRecognizerResult *res = g_getResult(stream);
    int rc = 0;
    if (res && res->text) snprintf(out, out_cap, "%s", res->text);
    else { snprintf(out, out_cap, ""); rc = 3; }
    if (res) g_destroyRes(res);
    g_destroyStr(stream);
    return rc;
}

void sherpa_destroy(void *recognizer) {
    if (recognizer) g_destroyRec((const SherpaOnnxOfflineRecognizer *)recognizer);
}
