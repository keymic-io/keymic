#ifndef SPIKE_BRIDGE_H
#define SPIKE_BRIDGE_H

// dlopen onnx_dir 下的两个 dylib,用 sense_voice config 转写 wav_path。
// 成功返回 0 并把 transcript 写入 out;失败返回非 0 并把诊断写入 out。
int spike_transcribe(const char *onnx_dir,
                     const char *model_path,
                     const char *tokens_path,
                     const char *wav_path,
                     char *out, int out_cap);

#endif
