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

void sherpa_destroy(void *recognizer);

#endif
