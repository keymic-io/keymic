#include "SpikeBridge.h"
#include "c-api.h"          // sherpa v1.13.2 真实头 → struct 布局编译器精确管理
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef const SherpaOnnxOfflineRecognizer *(*Fn_CreateRec)(const SherpaOnnxOfflineRecognizerConfig *);
typedef const SherpaOnnxOfflineStream *(*Fn_CreateStream)(const SherpaOnnxOfflineRecognizer *);
typedef void (*Fn_Accept)(const SherpaOnnxOfflineStream *, int32_t, const float *, int32_t);
typedef void (*Fn_Decode)(const SherpaOnnxOfflineRecognizer *, const SherpaOnnxOfflineStream *);
typedef const SherpaOnnxOfflineRecognizerResult *(*Fn_GetResult)(const SherpaOnnxOfflineStream *);
typedef void (*Fn_DestroyResult)(const SherpaOnnxOfflineRecognizerResult *);
typedef void (*Fn_DestroyStream)(const SherpaOnnxOfflineStream *);
typedef void (*Fn_DestroyRec)(const SherpaOnnxOfflineRecognizer *);
typedef const SherpaOnnxWave *(*Fn_ReadWave)(const char *);
typedef void (*Fn_FreeWave)(const SherpaOnnxWave *);

// 已解析的 sherpa offline C API 符号集合(dlopen+dlsym 一次,两条路径共用)。
typedef struct SherpaApi {
    Fn_CreateRec     createRec;
    Fn_CreateStream  createStream;
    Fn_Accept        accept;
    Fn_Decode        decode;
    Fn_GetResult     getResult;
    Fn_DestroyResult destroyRes;
    Fn_DestroyStream destroyStr;
    Fn_DestroyRec    destroyRec;
    Fn_ReadWave      readWave;
    Fn_FreeWave      freeWave;
} SherpaApi;

// dlopen onnx_dir 下的两个 dylib 并 dlsym 全部所需符号。
// 成功返回 0;失败返回非 0 并把诊断写入 out。这是 CTC 与 AR 两条路径共用的加载器。
static int load_sherpa(const char *onnx_dir, SherpaApi *api, char *out, int out_cap) {
    char onnxPath[2048], sherpaPath[2048];
    // 注意:必须用版本化名 libonnxruntime.1.24.4.dylib(sherpa 的 @rpath 依赖串)
    snprintf(onnxPath, sizeof(onnxPath), "%s/libonnxruntime.1.24.4.dylib", onnx_dir);
    snprintf(sherpaPath, sizeof(sherpaPath), "%s/libsherpa-onnx-c-api.dylib", onnx_dir);

    // 先 onnxruntime(RTLD_GLOBAL),再 sherpa(其 @loader_path/@rpath 依赖随之满足)
    void *honnx = dlopen(onnxPath, RTLD_NOW | RTLD_GLOBAL);
    if (!honnx) { snprintf(out, out_cap, "dlopen onnxruntime FAIL: %s", dlerror()); return 1; }
    void *hsherpa = dlopen(sherpaPath, RTLD_NOW | RTLD_GLOBAL);
    if (!hsherpa) { snprintf(out, out_cap, "dlopen sherpa FAIL: %s", dlerror()); return 2; }

    api->createRec    = (Fn_CreateRec)dlsym(hsherpa, "SherpaOnnxCreateOfflineRecognizer");
    api->createStream = (Fn_CreateStream)dlsym(hsherpa, "SherpaOnnxCreateOfflineStream");
    api->accept       = (Fn_Accept)dlsym(hsherpa, "SherpaOnnxAcceptWaveformOffline");
    api->decode       = (Fn_Decode)dlsym(hsherpa, "SherpaOnnxDecodeOfflineStream");
    api->getResult    = (Fn_GetResult)dlsym(hsherpa, "SherpaOnnxGetOfflineStreamResult");
    api->destroyRes   = (Fn_DestroyResult)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizerResult");
    api->destroyStr   = (Fn_DestroyStream)dlsym(hsherpa, "SherpaOnnxDestroyOfflineStream");
    api->destroyRec   = (Fn_DestroyRec)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizer");
    api->readWave     = (Fn_ReadWave)dlsym(hsherpa, "SherpaOnnxReadWave");
    api->freeWave     = (Fn_FreeWave)dlsym(hsherpa, "SherpaOnnxFreeWave");

    if (!api->createRec || !api->createStream || !api->accept || !api->decode ||
        !api->getResult || !api->destroyRes || !api->destroyStr || !api->destroyRec ||
        !api->readWave || !api->freeWave) {
        snprintf(out, out_cap, "dlsym FAIL: one or more symbols null"); return 3;
    }
    return 0;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

int spike_transcribe(const char *onnx_dir, const char *model_path,
                     const char *tokens_path, const char *wav_path,
                     char *out, int out_cap) {
    SherpaApi api;
    int lrc = load_sherpa(onnx_dir, &api, out, out_cap);
    if (lrc != 0) return lrc;

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    // 此 "funasr-nano" repo 的 artifact 实为 SenseVoice-CTC 格式(model_type=sense_voice_ctc),
    // 用 sense_voice config —— 不是同名的 model_config.funasr_nano(那需 4 个文件:
    // encoder_adaptor/llm/embedding/Qwen3 tokenizer,见 spike_ar_decode)。
    config.model_config.sense_voice.model = model_path;
    config.model_config.sense_voice.language = "auto";
    config.model_config.sense_voice.use_itn = 1;
    config.model_config.tokens = tokens_path;
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.model_config.debug = 1;
    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *rec = api.createRec(&config);
    if (!rec) { snprintf(out, out_cap, "CreateOfflineRecognizer NULL"); return 4; }

    const SherpaOnnxWave *wave = api.readWave(wav_path);
    if (!wave) { snprintf(out, out_cap, "ReadWave NULL: %s", wav_path); api.destroyRec(rec); return 5; }

    const SherpaOnnxOfflineStream *stream = api.createStream(rec);
    if (!stream) { snprintf(out, out_cap, "CreateOfflineStream NULL"); api.freeWave(wave); api.destroyRec(rec); return 7; }
    api.accept(stream, wave->sample_rate, wave->samples, wave->num_samples);
    api.decode(rec, stream);
    const SherpaOnnxOfflineRecognizerResult *res = api.getResult(stream);
    int rc = 0;
    if (res && res->text) snprintf(out, out_cap, "%s", res->text);
    else { snprintf(out, out_cap, "(empty result)"); rc = 6; }

    if (res) api.destroyRes(res);
    api.destroyStr(stream);
    api.freeWave(wave);
    api.destroyRec(rec);
    return rc;
}

// AR (autoregressive) funasr_nano 路径。recognizer init 加载 0.6B LLM,昂贵且只做一次;
// decode 每条 utterance 一次。两者分开计时。recognizer 缓存在 static 句柄,跨调用复用。
int spike_ar_decode(const char *onnx_dir, const char *model_dir, const char *wav_path,
                    char *out, int out_cap, double *init_ms, double *decode_ms) {
    static SherpaApi s_api;
    static const SherpaOnnxOfflineRecognizer *s_rec = NULL;
    static int s_loaded = 0;

    if (init_ms)   *init_ms = 0.0;
    if (decode_ms) *decode_ms = 0.0;

    // 一次性:dlopen + 创建 recognizer(计入 init_ms)。
    if (!s_loaded) {
        int lrc = load_sherpa(onnx_dir, &s_api, out, out_cap);
        if (lrc != 0) return lrc;

        // funasr_nano 的 tokenizer 期望是 *目录*(内含 tokenizer.json / vocab.json / merges.txt)。
        // dylib 错误串确认:'%s/tokenizer.json' does not exist. Please check --funasr-nano-tokenizer
        char encoderAdaptor[2048], llm[2048], embedding[2048], tokenizer[2048];
        snprintf(encoderAdaptor, sizeof(encoderAdaptor), "%s/encoder_adaptor.int8.onnx", model_dir);
        snprintf(llm,            sizeof(llm),            "%s/llm.int8.onnx",            model_dir);
        snprintf(embedding,      sizeof(embedding),      "%s/embedding.int8.onnx",      model_dir);
        snprintf(tokenizer,      sizeof(tokenizer),      "%s/Qwen3-0.6B",               model_dir);

        SherpaOnnxOfflineRecognizerConfig config;
        memset(&config, 0, sizeof(config));
        config.feat_config.sample_rate = 16000;
        config.feat_config.feature_dim = 80;

        config.model_config.funasr_nano.encoder_adaptor = encoderAdaptor;
        config.model_config.funasr_nano.llm             = llm;
        config.model_config.funasr_nano.embedding       = embedding;
        config.model_config.funasr_nano.tokenizer       = tokenizer; // 目录
        // 确定性贪心解码:temperature=0,固定 seed。
        config.model_config.funasr_nano.max_new_tokens  = 200;
        config.model_config.funasr_nano.temperature     = 0.0f;
        config.model_config.funasr_nano.top_p           = 1.0f;
        config.model_config.funasr_nano.seed            = 42;
        config.model_config.funasr_nano.language        = "auto";
        config.model_config.funasr_nano.itn             = 1;
        // system_prompt / user_prompt / hotwords 留 NULL(impl 内部有默认值)。

        // AR 用 Qwen3 tokenizer,不用 tokens.txt → model_config.tokens 留 NULL。
        config.model_config.num_threads = 2;
        config.model_config.provider = "cpu";
        config.model_config.debug = 0;
        config.decoding_method = "greedy_search";

        double t0 = now_ms();
        s_rec = s_api.createRec(&config);
        double t1 = now_ms();
        if (init_ms) *init_ms = t1 - t0;

        if (!s_rec) { snprintf(out, out_cap, "CreateOfflineRecognizer (AR) NULL"); return 4; }
        s_loaded = 1;
    }

    const SherpaOnnxWave *wave = s_api.readWave(wav_path);
    if (!wave) { snprintf(out, out_cap, "ReadWave NULL: %s", wav_path); return 5; }

    double d0 = now_ms();
    const SherpaOnnxOfflineStream *stream = s_api.createStream(s_rec);
    if (!stream) { snprintf(out, out_cap, "CreateOfflineStream (AR) NULL"); s_api.freeWave(wave); return 7; }
    s_api.accept(stream, wave->sample_rate, wave->samples, wave->num_samples);
    s_api.decode(s_rec, stream);
    const SherpaOnnxOfflineRecognizerResult *res = s_api.getResult(stream);
    double d1 = now_ms();
    if (decode_ms) *decode_ms = d1 - d0;

    int rc = 0;
    if (res && res->text) snprintf(out, out_cap, "%s", res->text);
    else { snprintf(out, out_cap, "(empty result)"); rc = 6; }

    if (res) s_api.destroyRes(res);
    s_api.destroyStr(stream);
    s_api.freeWave(wave);
    // 不销毁 s_rec —— 复用以分摊 0.6B LLM 加载成本。
    return rc;
}
