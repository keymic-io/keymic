# ONNX / sherpa-onnx dlopen spike — asset prep notes (Task 1)

De-risking spike: prove a downloaded, **self-signed** dynamic framework can be
`dlopen`'d under the Hardened Runtime + `com.apple.security.cs.disable-library-validation`
entitlement and run FunASR-Nano (actually **SenseVoice** — see big finding below)
transcription.

This file records everything Task 1 gathered so the rest of the spike is reproducible.
**Large binaries (dylibs + model.onnx) live in `~/Library/Application Support/KeyMic/`,
never in git.** Only this README and `vendor/c-api.h` are committed.

---

## 1. sherpa-onnx prebuilt dynamic framework

- **Release tag:** `v1.13.2` (k2-fsa/sherpa-onnx), published 2026-05-13.
  - `SherpaOnnxGetVersionStr()` → `1.13.2`
  - Git SHA1 `13d0ae6c`, Git date `Wed May 13 10:53:59 2026`
  - (latest stable at time of spike; postdates the 2025-12-17 model, so it has FunASR/SenseVoice support)
- **Tarball (the `-shared` universal2 variant, NOT static):**
  - Name: `sherpa-onnx-v1.13.2-osx-universal2-shared.tar.bz2`
  - URL: <https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-osx-universal2-shared.tar.bz2>
  - Download size: 55,332,221 bytes (~55 MB)
- Extracted layout (relevant parts):
  - `lib/libsherpa-onnx-c-api.dylib`        ← the C API dylib (this spike's target)
  - `lib/libsherpa-onnx-cxx-api.dylib`      (C++ API, not used)
  - `lib/libonnxruntime.1.24.4.dylib`       ← onnxruntime backend (versioned)
  - `lib/libonnxruntime.dylib`              ← **byte-identical copy** of the versioned one (NOT a symlink; same MD5 `fd03f033...`)
  - `include/sherpa-onnx/c-api/c-api.h`     ← captured to `vendor/c-api.h`
  - `include/sherpa-onnx/c-api/cxx-api.h`
  - `bin/sherpa-onnx-offline` + ~30 other CLI tools (ground-truth reference for Task 6)

### Dylib inspection (verification gate — ALL PASS)

```
$ lipo -info libsherpa-onnx-c-api.dylib
Architectures in the fat file: ... are: x86_64 arm64          # universal2 ✓
$ lipo -info libonnxruntime.1.24.4.dylib
Architectures in the fat file: ... are: x86_64 arm64          # universal2 ✓

$ nm -gU libsherpa-onnx-c-api.dylib | grep -c "T _SherpaOnnx"
170                                                            # 170 exported C symbols ✓
# includes _SherpaOnnxCreateOfflineRecognizer, _SherpaOnnxGetVersionStr,
#          _SherpaOnnxCreateOfflineStream, _SherpaOnnxDecodeOfflineStream,
#          _SherpaOnnxGetOfflineStreamResult, _SherpaOnnxReadWave, ...

$ otool -L libsherpa-onnx-c-api.dylib       # both arches identical:
        @rpath/libsherpa-onnx-c-api.dylib   (compat 0.0.0, current 0.0.0)
        /usr/lib/libSystem.B.dylib
        @rpath/libonnxruntime.1.24.4.dylib  (compat 0.0.0, current 1.24.4)   ← onnxruntime dep
        /usr/lib/libc++.1.dylib
```

### CRITICAL install-name / rpath facts for Task 5 (rpath wiring)

| dylib                          | `LC_ID_DYLIB` (install name)        | notes |
|--------------------------------|-------------------------------------|-------|
| `libsherpa-onnx-c-api.dylib`   | `@rpath/libsherpa-onnx-c-api.dylib` | links against `@rpath/libonnxruntime.1.24.4.dylib` |
| `libonnxruntime.1.24.4.dylib`  | `@rpath/libonnxruntime.1.24.4.dylib`| the real backend |
| `libonnxruntime.dylib`         | `@rpath/libonnxruntime.1.24.4.dylib`| identical copy; its OWN id is STILL the versioned name |

- `libsherpa-onnx-c-api.dylib` has exactly one `LC_RPATH`: **`@loader_path`**.
- Therefore at load time the sherpa dylib resolves its onnxruntime dependency to
  `@loader_path/libonnxruntime.1.24.4.dylib` — i.e. it looks for the **versioned
  filename** sitting next to it.
- **Implication for Task 5:** the onnxruntime dylib must be present next to the sherpa
  dylib under the *versioned* name `libonnxruntime.1.24.4.dylib`. Renaming it to plain
  `libonnxruntime.dylib` is NOT sufficient on its own (the dependency string in the
  sherpa dylib is `libonnxruntime.1.24.4.dylib`). Options for Task 5:
  1. keep/ship `libonnxruntime.1.24.4.dylib` next to the sherpa dylib (simplest — done here), OR
  2. symlink `libonnxruntime.1.24.4.dylib -> libonnxruntime.dylib`, OR
  3. `install_name_tool -change @rpath/libonnxruntime.1.24.4.dylib @rpath/libonnxruntime.dylib libsherpa-onnx-c-api.dylib`
     (note: this re-signs the dylib → cdhash changes → must re-codesign).
- The unsigned downloaded `bin/sherpa-onnx-version` ran fine under
  `DYLD_LIBRARY_PATH=lib` and printed the version, so the dylibs are loadable as shipped
  (no notarization needed for local dlopen).

---

## 2. Model — `csukuangfj/sherpa-onnx-sense-voice-funasr-nano-2025-12-17`

HuggingFace repo (created 2025-12-17, last modified 2026-01-05). Full file layout
(from `/api/models/.../tree/main`):

| path                  | size (bytes)   | notes |
|-----------------------|----------------|-------|
| `model.onnx`          | 1,034,022,083  | LFS, ~1.03 GB |
| `tokens.txt`          | 939,815        | base64-encoded token table (FunASR/SenseVoice style) |
| `test_wavs/en.wav`    | 228,908        | mono 16 kHz 16-bit PCM |
| `test_wavs/ja.wav`    | 230,444        | mono 16 kHz 16-bit PCM |
| `test_wavs/ko.wav`    | 147,500        | mono 16 kHz 16-bit PCM |
| `test_wavs/yue.wav`   | 164,780        | mono 16 kHz 16-bit PCM |
| `test_wavs/zh.wav`    | 178,988        | mono 16 kHz 16-bit PCM |
| `README` / `README.md`| 1,916          | describes "Fun-ASR-Nano-2512", no sherpa config example |

- `model.onnx` downloaded size **exactly** 1,034,022,083 bytes; **SHA256 verified**
  against HF LFS oid: `b3157083560dc23a68b715ac97fe3a7a689d6aa93c2bd93289ad3ee13b14290a`.
  Header bytes confirm real ONNX protobuf (`...pytorch..2.0`), NOT an HTML error page.
- `tokens.txt` present, 939,815 bytes (matches HF).
- **5 bundled test WAVs** (all 16 kHz mono PCM, ideal for Task 4 fixtures):
  - `~/Library/Application Support/KeyMic/models/funasr-nano/test_wavs/{en,ja,ko,yue,zh}.wav`
  - Languages en/ja/ko/yue/zh line up exactly with SenseVoice's `--sense-voice-language`
    valid values (`auto, zh, en, ja, ko, yue`).

### ⚠️ BIG FINDING — this model is a **SenseVoice** model, not the `funasr_nano` config

Despite the repo *name* containing "funasr-nano", the downloaded artifact must be loaded
as a **SenseVoice** model in sherpa-onnx, NOT via the `funasr_nano` config. Evidence:

1. **Embedded ONNX metadata** (`strings model.onnx`) contains `model_type = sense_voice_ctc`,
   plus SenseVoice feature params `lfr_window_size`, `lfr_window_shift`, `normalize_samples`.
2. **The repo layout is the SenseVoice layout** — a single `model.onnx` + `tokens.txt`.
3. **The c-api.h `funasr_nano` config expects 4 separate files** (encoder_adaptor, llm,
   embedding, tokenizer dir) that this repo does NOT ship. Confirmed by
   `bin/sherpa-onnx-offline --help`:
   - FunASR-nano (model type 7) needs:
     `--funasr-nano-encoder-adaptor`, `--funasr-nano-llm`, `--funasr-nano-embedding`,
     `--funasr-nano-tokenizer=/path/to/Qwen3-0.6B` (a Qwen3-0.6B LLM tokenizer dir).
   - This repo has none of those — only `model.onnx` + `tokens.txt`.
   - SenseVoice (the matching type) needs just `--sense-voice-model=model.onnx` +
     `--tokens=tokens.txt` (+ optional `--sense-voice-language`).

**Decision input for Task 2/6:** load via `SherpaOnnxOfflineSenseVoiceModelConfig`
(`model_config.sense_voice.model` = model.onnx path, `model_config.tokens` = tokens.txt),
NOT `model_config.funasr_nano`. The directory is still named `funasr-nano` per the plan's
fixed path, but the *config struct* to fill is `sense_voice`.

### Relevant c-api.h structs (captured in `vendor/c-api.h`)

`SherpaOnnxOfflineSenseVoiceModelConfig` (the one to use here):
```c
typedef struct SherpaOnnxOfflineSenseVoiceModelConfig {
  const char *model;     // path to model.onnx
  const char *language;  // "auto"|"zh"|"en"|"ja"|"ko"|"yue"
  int32_t use_itn;       // inverse text normalization
} SherpaOnnxOfflineSenseVoiceModelConfig;
```
`tokens` lives on the parent `SherpaOnnxOfflineModelConfig.tokens` (line ~1059), which
also holds `num_threads`, `debug`, `provider`, and the `sense_voice` sub-struct (line ~1075).

For reference, the (unused-here) FunASR-Nano struct is at c-api.h line ~969
(`SherpaOnnxOfflineFunASRNanoModelConfig`: encoder_adaptor / llm / embedding / tokenizer /
system_prompt / user_prompt / max_new_tokens / temperature / top_p / seed / language /
itn / hotwords).

---

## 3. Final on-disk asset placement

```
~/Library/Application Support/KeyMic/
├── onnx-runtime/
│   ├── libsherpa-onnx-c-api.dylib       8,522,360 bytes   (universal2, 170 C symbols)
│   ├── libonnxruntime.1.24.4.dylib     55,913,360 bytes   (versioned — what @rpath resolves to)
│   └── libonnxruntime.dylib            55,913,360 bytes   (identical copy; the Task-1 "renamed" target)
└── models/funasr-nano/
    ├── model.onnx                   1,034,022,083 bytes   (SenseVoice; sha256 b3157083...)
    ├── tokens.txt                         939,815 bytes
    └── test_wavs/{en,ja,ko,yue,zh}.wav    (5 files, 16 kHz mono PCM)
```

Note both `libonnxruntime.dylib` AND `libonnxruntime.1.24.4.dylib` are placed. The
versioned one is what the sherpa dylib's `@rpath` dependency actually needs; the plain
name is there per Task 1's rename instruction. Task 5 should rely on the **versioned**
name being present next to the sherpa dylib.

---

## 4. Reproducible placement commands (exactly what was run)

```bash
# Working temp dir
TMP="$CLAUDE_JOB_DIR/tmp"            # any scratch dir
APPSUP="$HOME/Library/Application Support/KeyMic"
mkdir -p "$APPSUP/onnx-runtime" "$APPSUP/models/funasr-nano/test_wavs"

# --- sherpa-onnx dynamic framework (v1.13.2 universal2 shared) ---
cd "$TMP"
curl -sL -o sherpa.tar.bz2 \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-osx-universal2-shared.tar.bz2"
tar -xjf sherpa.tar.bz2
LIB="$TMP/sherpa-onnx-v1.13.2-osx-universal2-shared/lib"

# Verify (gate)
lipo -info "$LIB/libsherpa-onnx-c-api.dylib"                                   # x86_64 arm64
nm -gU "$LIB/libsherpa-onnx-c-api.dylib" | grep -iE "OfflineRecognizer|GetVersionStr"
otool -L "$LIB/libsherpa-onnx-c-api.dylib" | grep -i onnxruntime               # @rpath/libonnxruntime.1.24.4.dylib

# Place dylibs (rename + keep versioned name for @rpath resolution)
cp "$LIB/libsherpa-onnx-c-api.dylib"   "$APPSUP/onnx-runtime/libsherpa-onnx-c-api.dylib"
cp "$LIB/libonnxruntime.1.24.4.dylib"  "$APPSUP/onnx-runtime/libonnxruntime.dylib"
cp "$LIB/libonnxruntime.1.24.4.dylib"  "$APPSUP/onnx-runtime/libonnxruntime.1.24.4.dylib"

# --- model (SenseVoice, single model.onnx + tokens.txt + test WAVs) ---
BASE="https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-funasr-nano-2025-12-17/resolve/main"
MODELDIR="$APPSUP/models/funasr-nano"
curl -sL -o "$MODELDIR/model.onnx" "$BASE/model.onnx"        # ~1.03 GB
curl -sL -o "$MODELDIR/tokens.txt" "$BASE/tokens.txt"
for w in en ja ko yue zh; do
  curl -sL -o "$MODELDIR/test_wavs/$w.wav" "$BASE/test_wavs/$w.wav"
done

# Verify model integrity
shasum -a 256 "$MODELDIR/model.onnx"   # b3157083560dc23a68b715ac97fe3a7a689d6aa93c2bd93289ad3ee13b14290a

# --- capture the header into the spike (the ONLY large-ish file committed) ---
cp "$TMP/sherpa-onnx-v1.13.2-osx-universal2-shared/include/sherpa-onnx/c-api/c-api.h" \
   Tests/Spikes/vendor/c-api.h
```

### Quick smoke check (ground truth for Task 6 — optional)
The shipped `bin/sherpa-onnx-offline` CLI can transcribe the test WAVs directly as a
SenseVoice model (sanity baseline before the dlopen shim exists):
```bash
DYLD_LIBRARY_PATH="$LIB" "$TMP/sherpa-onnx-v1.13.2-osx-universal2-shared/bin/sherpa-onnx-offline" \
  --sense-voice-model="$MODELDIR/model.onnx" \
  --tokens="$MODELDIR/tokens.txt" \
  --sense-voice-language=auto \
  "$MODELDIR/test_wavs/zh.wav"
```
