#ifndef SHERPA_BRIDGE_H
#define SHERPA_BRIDGE_H

// dlopen onnx_dir 下 libonnxruntime.1.24.4.dylib + libsherpa-onnx-c-api.dylib 并 dlsym 全部符号。
// 成功 0;失败非 0 并把诊断写入 err。可重复调用(已加载则直接返回 0)。
int sherpa_load(const char *onnx_dir, char *err, int err_cap);

// 用 funasr_nano (AR) config 建 OfflineRecognizer。tokenizer_dir 为 Qwen3-0.6B 目录。
// 成功返回不透明 recognizer 句柄;失败返回 NULL 并把诊断写入 err。须先 sherpa_load 成功。
void *sherpa_create_funasr(const char *encoder_adaptor,
                           const char *llm,
                           const char *embedding,
                           const char *tokenizer_dir,
                           char *err, int err_cap);

// 用 recognizer 解码 16k mono float [-1,1] 整段音频。成功 0 + transcript 写入 out;失败非 0。
int sherpa_decode(void *recognizer,
                  const float *samples, int n, int sample_rate,
                  char *out, int out_cap);

// ---- Streaming (OnlineRecognizer) API (M1) ----
// 须先 sherpa_load 成功。用 streaming-zipformer transducer config 建 OnlineRecognizer + 一条 stream。
// model_dir 下须有 encoder.onnx / decoder.onnx / joiner.onnx / tokens.txt。
// 成功返回不透明句柄(内部含 recognizer+stream);失败返回 NULL 并把诊断写入 err。
void *sherpa_create_online(const char *model_dir, char *err, int err_cap);

// 喂入一块 16k mono float [-1,1] 音频,并把所有 ready 的帧解码完。线程不安全:
// 同一 handle 的全部调用须串行(单声道一个后台队列)。
void sherpa_online_accept(void *handle, const float *samples, int n, int sample_rate);

// 取当前累积(partial)文本写入 out。返回文本字节长度(不含结尾 '\0'),失败返回 -1。
int sherpa_online_result(void *handle, char *out, int out_cap);

// 端点检测:1 = 已到端点(应取 final 并 reset);0 = 否;-1 = 错误。
int sherpa_online_is_endpoint(void *handle);

// 端点后清解码状态,准备下一句。
void sherpa_online_reset(void *handle);

// 释放 handle(recognizer + stream)。
void sherpa_online_destroy(void *handle);

void sherpa_destroy(void *recognizer);

// ---- Offline speaker diarization (P2.2) ----
// 须先 sherpa_load 成功。对 16k mono float [-1,1] 整段音频跑离线说话人分离。
// seg_model = pyannote segmentation .onnx; embedding_model = 3D-Speaker campplus .onnx。
// threshold = 聚类距离阈值(num_clusters 内部取 -1 → 自动估计人数)。
// 结果分段(按 start 排序)写入 starts/ends/speakers(各 max_segs 容量)。
// 返回写入的分段数(>=0),或负数错误码并把诊断写入 err。
int sherpa_diarize(const char *seg_model, const char *embedding_model, float threshold,
                   const float *samples, int n,
                   float *starts, float *ends, int *speakers, int max_segs,
                   char *err, int err_cap);

#endif
