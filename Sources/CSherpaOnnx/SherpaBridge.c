#include "SherpaBridge.h"
#include "c-api.h"          // sherpa v1.13.2 真实头 → struct 布局编译器精确管理
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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

// ---- Streaming (Online) fn pointers ----
typedef const SherpaOnnxOnlineRecognizer *(*Fn_CreateOnlineRec)(const SherpaOnnxOnlineRecognizerConfig *);
typedef const SherpaOnnxOnlineStream *(*Fn_CreateOnlineStream)(const SherpaOnnxOnlineRecognizer *);
typedef void (*Fn_OnlineAccept)(const SherpaOnnxOnlineStream *, int32_t, const float *, int32_t);
typedef int32_t (*Fn_OnlineReady)(const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef void (*Fn_OnlineDecode)(const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef const SherpaOnnxOnlineRecognizerResult *(*Fn_OnlineGetResult)(const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef void (*Fn_OnlineDestroyResult)(const SherpaOnnxOnlineRecognizerResult *);
typedef int32_t (*Fn_OnlineIsEndpoint)(const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef void (*Fn_OnlineReset)(const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef void (*Fn_OnlineDestroyStream)(const SherpaOnnxOnlineStream *);
typedef void (*Fn_OnlineDestroyRec)(const SherpaOnnxOnlineRecognizer *);

static Fn_CreateOnlineRec     g_onCreateRec;
static Fn_CreateOnlineStream  g_onCreateStream;
static Fn_OnlineAccept        g_onAccept;
static Fn_OnlineReady         g_onReady;
static Fn_OnlineDecode        g_onDecode;
static Fn_OnlineGetResult     g_onGetResult;
static Fn_OnlineDestroyResult g_onDestroyResult;
static Fn_OnlineIsEndpoint    g_onIsEndpoint;
static Fn_OnlineReset         g_onReset;
static Fn_OnlineDestroyStream g_onDestroyStream;
static Fn_OnlineDestroyRec    g_onDestroyRec;

// 内部句柄:绑定一个 recognizer 与它的一条 stream(单声道单流)。
typedef struct {
    const SherpaOnnxOnlineRecognizer *rec;
    const SherpaOnnxOnlineStream *stream;
} OnlineHandle;

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
    g_onCreateRec     = (Fn_CreateOnlineRec)dlsym(hsherpa, "SherpaOnnxCreateOnlineRecognizer");
    g_onCreateStream  = (Fn_CreateOnlineStream)dlsym(hsherpa, "SherpaOnnxCreateOnlineStream");
    g_onAccept        = (Fn_OnlineAccept)dlsym(hsherpa, "SherpaOnnxOnlineStreamAcceptWaveform");
    g_onReady         = (Fn_OnlineReady)dlsym(hsherpa, "SherpaOnnxIsOnlineStreamReady");
    g_onDecode        = (Fn_OnlineDecode)dlsym(hsherpa, "SherpaOnnxDecodeOnlineStream");
    g_onGetResult     = (Fn_OnlineGetResult)dlsym(hsherpa, "SherpaOnnxGetOnlineStreamResult");
    g_onDestroyResult = (Fn_OnlineDestroyResult)dlsym(hsherpa, "SherpaOnnxDestroyOnlineRecognizerResult");
    g_onIsEndpoint    = (Fn_OnlineIsEndpoint)dlsym(hsherpa, "SherpaOnnxOnlineStreamIsEndpoint");
    g_onReset         = (Fn_OnlineReset)dlsym(hsherpa, "SherpaOnnxOnlineStreamReset");
    g_onDestroyStream = (Fn_OnlineDestroyStream)dlsym(hsherpa, "SherpaOnnxDestroyOnlineStream");
    g_onDestroyRec    = (Fn_OnlineDestroyRec)dlsym(hsherpa, "SherpaOnnxDestroyOnlineRecognizer");
    if (!g_onCreateRec || !g_onCreateStream || !g_onAccept || !g_onReady || !g_onDecode ||
        !g_onGetResult || !g_onDestroyResult || !g_onIsEndpoint || !g_onReset ||
        !g_onDestroyStream || !g_onDestroyRec) {
        snprintf(err, err_cap, "dlsym FAIL: one or more online symbols null"); return 4;
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
    // 按应用录音上限(6 分钟)定容:360s × ~7 token/s(快速中文 ~5 字/s ≈ 5 token/s,
    // 英文 wordpiece 更碎)≈ 2520,取 3000 留余量。max_new_tokens 只是生成上限,
    // greedy 解码遇 EOS 即停,大 cap 对短语音零成本;200 会把 ~200 字后的内容静默截断。
    // (该字段是创建期配置,无法按单次解码的音频时长动态调整;Swift 侧输出缓冲
    //  已同步放大,见 ONNXSpeechEngine.endAudio。)
    config.model_config.funasr_nano.max_new_tokens  = 3000;
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

void *sherpa_create_online(const char *model_dir, char *err, int err_cap) {
    if (!g_loaded) { snprintf(err, err_cap, "sherpa_load not called"); return NULL; }
    char enc[2048], dec[2048], joi[2048], tok[2048];
    snprintf(enc, sizeof(enc), "%s/encoder.onnx", model_dir);
    snprintf(dec, sizeof(dec), "%s/decoder.onnx", model_dir);
    snprintf(joi, sizeof(joi), "%s/joiner.onnx", model_dir);
    snprintf(tok, sizeof(tok), "%s/tokens.txt", model_dir);

    SherpaOnnxOnlineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = enc;
    config.model_config.transducer.decoder = dec;
    config.model_config.transducer.joiner  = joi;
    config.model_config.tokens      = tok;
    config.model_config.num_threads = 2;
    config.model_config.provider    = "cpu";
    config.model_config.debug       = 0;
    config.decoding_method = "greedy_search";
    // 端点检测:2s 尾静音收一句;长句兜底 20s 强制切分(会议里有人不停说时仍能落段)。
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = 2.4f;
    config.rule2_min_trailing_silence = 1.2f;
    config.rule3_min_utterance_length = 20.0f;

    const SherpaOnnxOnlineRecognizer *rec = g_onCreateRec(&config);
    if (!rec) { snprintf(err, err_cap, "CreateOnlineRecognizer NULL"); return NULL; }
    const SherpaOnnxOnlineStream *stream = g_onCreateStream(rec);
    if (!stream) { snprintf(err, err_cap, "CreateOnlineStream NULL"); g_onDestroyRec(rec); return NULL; }
    OnlineHandle *h = (OnlineHandle *)calloc(1, sizeof(OnlineHandle));
    if (!h) { snprintf(err, err_cap, "calloc NULL"); g_onDestroyStream(stream); g_onDestroyRec(rec); return NULL; }
    h->rec = rec; h->stream = stream;
    return (void *)h;
}

void sherpa_online_accept(void *handle, const float *samples, int n, int sample_rate) {
    if (!handle || !samples || n <= 0) return;
    OnlineHandle *h = (OnlineHandle *)handle;
    g_onAccept(h->stream, sample_rate, samples, n);
    while (g_onReady(h->rec, h->stream)) {
        g_onDecode(h->rec, h->stream);
    }
}

int sherpa_online_result(void *handle, char *out, int out_cap) {
    if (!handle || !out || out_cap <= 0) return -1;
    OnlineHandle *h = (OnlineHandle *)handle;
    const SherpaOnnxOnlineRecognizerResult *r = g_onGetResult(h->rec, h->stream);
    if (!r) { if (out_cap > 0) out[0] = '\0'; return -1; }
    int len = 0;
    if (r->text) { snprintf(out, out_cap, "%s", r->text); len = (int)strlen(out); }
    else if (out_cap > 0) out[0] = '\0';
    g_onDestroyResult(r);
    return len;
}

int sherpa_online_is_endpoint(void *handle) {
    if (!handle) return -1;
    OnlineHandle *h = (OnlineHandle *)handle;
    return (int)g_onIsEndpoint(h->rec, h->stream);
}

void sherpa_online_reset(void *handle) {
    if (!handle) return;
    OnlineHandle *h = (OnlineHandle *)handle;
    g_onReset(h->rec, h->stream);
}

void sherpa_online_destroy(void *handle) {
    if (!handle) return;
    OnlineHandle *h = (OnlineHandle *)handle;
    if (h->stream) g_onDestroyStream(h->stream);
    if (h->rec) g_onDestroyRec(h->rec);
    free(h);
}
