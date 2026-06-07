#include "SpikeBridge.h"
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
typedef const SherpaOnnxWave *(*Fn_ReadWave)(const char *);
typedef void (*Fn_FreeWave)(const SherpaOnnxWave *);

int spike_transcribe(const char *onnx_dir, const char *model_path,
                     const char *tokens_path, const char *wav_path,
                     char *out, int out_cap) {
    char onnxPath[2048], sherpaPath[2048];
    // 注意:必须用版本化名 libonnxruntime.1.24.4.dylib(sherpa 的 @rpath 依赖串)
    snprintf(onnxPath, sizeof(onnxPath), "%s/libonnxruntime.1.24.4.dylib", onnx_dir);
    snprintf(sherpaPath, sizeof(sherpaPath), "%s/libsherpa-onnx-c-api.dylib", onnx_dir);

    // 先 onnxruntime(RTLD_GLOBAL),再 sherpa(其 @loader_path/@rpath 依赖随之满足)
    void *honnx = dlopen(onnxPath, RTLD_NOW | RTLD_GLOBAL);
    if (!honnx) { snprintf(out, out_cap, "dlopen onnxruntime FAIL: %s", dlerror()); return 1; }
    void *hsherpa = dlopen(sherpaPath, RTLD_NOW | RTLD_GLOBAL);
    if (!hsherpa) { snprintf(out, out_cap, "dlopen sherpa FAIL: %s", dlerror()); return 2; }

    Fn_CreateRec     createRec   = (Fn_CreateRec)dlsym(hsherpa, "SherpaOnnxCreateOfflineRecognizer");
    Fn_CreateStream  createStream= (Fn_CreateStream)dlsym(hsherpa, "SherpaOnnxCreateOfflineStream");
    Fn_Accept        accept      = (Fn_Accept)dlsym(hsherpa, "SherpaOnnxAcceptWaveformOffline");
    Fn_Decode        decode      = (Fn_Decode)dlsym(hsherpa, "SherpaOnnxDecodeOfflineStream");
    Fn_GetResult     getResult   = (Fn_GetResult)dlsym(hsherpa, "SherpaOnnxGetOfflineStreamResult");
    Fn_DestroyResult destroyRes  = (Fn_DestroyResult)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizerResult");
    Fn_DestroyStream destroyStr  = (Fn_DestroyStream)dlsym(hsherpa, "SherpaOnnxDestroyOfflineStream");
    Fn_DestroyRec    destroyRec  = (Fn_DestroyRec)dlsym(hsherpa, "SherpaOnnxDestroyOfflineRecognizer");
    Fn_ReadWave      readWave    = (Fn_ReadWave)dlsym(hsherpa, "SherpaOnnxReadWave");
    Fn_FreeWave      freeWave    = (Fn_FreeWave)dlsym(hsherpa, "SherpaOnnxFreeWave");

    if (!createRec || !createStream || !accept || !decode || !getResult ||
        !destroyRes || !destroyStr || !destroyRec || !readWave || !freeWave) {
        snprintf(out, out_cap, "dlsym FAIL: one or more symbols null"); return 3;
    }

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.sense_voice.model = model_path;
    config.model_config.sense_voice.language = "auto";
    config.model_config.sense_voice.use_itn = 1;
    config.model_config.tokens = tokens_path;
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.model_config.debug = 1;
    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *rec = createRec(&config);
    if (!rec) { snprintf(out, out_cap, "CreateOfflineRecognizer NULL"); return 4; }

    const SherpaOnnxWave *wave = readWave(wav_path);
    if (!wave) { snprintf(out, out_cap, "ReadWave NULL: %s", wav_path); destroyRec(rec); return 5; }

    const SherpaOnnxOfflineStream *stream = createStream(rec);
    accept(stream, wave->sample_rate, wave->samples, wave->num_samples);
    decode(rec, stream);
    const SherpaOnnxOfflineRecognizerResult *res = getResult(stream);
    int rc = 0;
    if (res && res->text) snprintf(out, out_cap, "%s", res->text);
    else { snprintf(out, out_cap, "(empty result)"); rc = 6; }

    if (res) destroyRes(res);
    destroyStr(stream);
    freeWave(wave);
    destroyRec(rec);
    return rc;
}
