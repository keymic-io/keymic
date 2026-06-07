#ifndef SPIKE_BRIDGE_H
#define SPIKE_BRIDGE_H

// dlopen onnx_dir 下的两个 dylib,用 sense_voice config 转写 wav_path。
// 成功返回 0 并把 transcript 写入 out;失败返回非 0 并把诊断写入 out。
int spike_transcribe(const char *onnx_dir,
                     const char *model_path,
                     const char *tokens_path,
                     const char *wav_path,
                     char *out, int out_cap);

// AR (autoregressive) funasr_nano 路径。首次调用惰性初始化 recognizer
// (init 时间写入 *init_ms,否则写 0),解码 wav_path,transcript 写入 out,
// 解码时间写入 *decode_ms。成功返回 0,失败返回非 0 并把诊断写入 out。
// recognizer 缓存在 static 句柄,跨调用复用(分摊 0.6B LLM 加载成本)。
// model_dir 须含 encoder_adaptor.int8.onnx / llm.int8.onnx / embedding.int8.onnx
// 以及 Qwen3-0.6B/ 目录(tokenizer.json + vocab.json + merges.txt)。
int spike_ar_decode(const char *onnx_dir,
                    const char *model_dir,
                    const char *wav_path,
                    char *out, int out_cap,
                    double *init_ms, double *decode_ms);

#endif
