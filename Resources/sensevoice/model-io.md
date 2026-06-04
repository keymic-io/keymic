# SenseVoiceSmall CoreML — Measured Model I/O (Task 0 Spike)

All values below were **measured on this Mac** (darwin, Apple Silicon) by downloading the
prebuilt `.mlmodelc.zip`, unzipping it, and running the compiled CoreML model via the native
`CoreML` framework (a Swift probe — `coremltools` cannot load a bare `.mlmodelc`, it errors
`A valid manifest does not exist ... Manifest.json`). Cross-checked against the upstream
FunASR/SenseVoice `model.py` + `export_meta.py` and the conversion repo's `config.json`.

## Model artifact / distribution

| field | value |
| --- | --- |
| `modelDownloadURLString` | `https://huggingface.co/mefengl/SenseVoiceSmall-coreml/resolve/main/coreml/SenseVoiceSmall.mlmodelc.zip` |
| `modelSHA256` (of the zip) | `880711fa03577363e6c1b1b6e9321f130ea1a53d5c065d92e1abd8a431bad6be` |
| zip size | 432,164,139 bytes (~432 MB) |
| `modelDirName` (top-level entry inside zip) | `SenseVoiceSmall.mlmodelc` |
| storage precision | Float16 (compute: Mixed Float16/Int16/Int32/UInt16) |
| min deployment target | **macOS 15.0** (iOS 18 / specificationVersion 9). Converted with coremltools 9.0 from torch 2.3.1 / TorchScript. |

The SHA256 matches `config.json` in the conversion repo exactly. The zip unzips to a **single
top-level directory** named `SenseVoiceSmall.mlmodelc`, which is exactly what
`SenseVoiceModelStore.unzip(into: baseDir)` expects (it points `modelURL` at
`baseDir/<modelDirName>`). No nested folder — the model store's layout convention is confirmed.

> NOTE: deployment target is macOS 15. The KeyMic project targets macOS 14 (CLAUDE.md). The
> CoreML model will only load on macOS 15+. Task 7/8 fallback to the platform `SpeechEngine`
> must handle `MLModel(contentsOf:)` returning nil / throwing on macOS 14.

## Inputs (4) — all required; the exported graph takes language/textnorm as INT tensors

| name | dtype | shape | notes |
| --- | --- | --- | --- |
| `speech` | Float32 | `[1, T, 560]`, T flexible **1…3000** | LFR-fbank features. F=560 = melBins(80) × lfrM(7). |
| `speech_lengths` | Int32 | `[1]` | number of valid feature frames T. |
| `language` | Int32 | `[1]` | **embedding index** fed straight into `self.embed(language)`. See lid map below. |
| `textnorm` | Int32 | `[1]` | **embedding index**; 14=withitn (ITN on), 15=woitn (ITN off). Convert/sanity scripts use 15. |

The original (non-exported) `model.py` accepts string `language`/`textnorm` and looks them up
internally; the **exported CoreML model** (`export_meta.export_forward`) instead takes the
resolved INT embedding indices directly. So Task 7 must pass the integer ids below, NOT strings.

### language id map (from upstream `model.py` `self.lid_dict`)

```
auto=0, zh=3, en=4, yue=7, ja=11, ko=12, nospeech=13
```

### textnorm id map (from upstream `self.textnorm_dict`)

```
withitn=14 (apply inverse text normalization), woitn=15 (raw)
```

## Outputs (2)

| name | dtype | shape | notes |
| --- | --- | --- | --- |
| `ctc_logits` | **Float16** | `[1, T', V]` rank-3, **V = 25055** | RAW linear logits (`ctc.ctc_lo`, NOT log-softmaxed). Argmax-invariant so greedy CTC is fine. T' = T + 4 (model prepends 1 textnorm + 1 language + 2 event/emo embedding frames before the encoder). Metadata reports shape `[]` (dynamic); the rank/width were recovered by running a forward pass. |
| `encoder_out_lens` | Int32 | `[1]` | number of valid logit frames T' to read (the rest are padding). |

Measured example: input T=300 → `ctc_logits` `[1, 304, 25055]`, `encoder_out_lens=[304]`.
Golden fixture: input T=33 → `ctc_logits` `[1, 37, 25055]`, `encoder_out_lens=[37]`.

## Vocab + CTC blank

- **Vocab size = 25055**, confirmed two independent ways: (a) last dim of `ctc_logits` from a
  real forward pass = 25055; (b) the SentencePiece tokenizer `chn_jpn_yue_eng_ko_spectok.bpe.model`
  `get_piece_size()` = 25055. They match, so the CTC output indexes the SPM vocab directly.
- **`blankId = 0`** — config.json `decoding.ctc_blank_id = 0`. SPM piece[0] is `<unk>`; FunASR
  CTC reuses index 0 as the blank. `vocab.json` maps `"<unk>" -> 0`.
- SenseVoice control tokens live at the **top of the vocab** and must be stripped from decoded
  text. Language tags `<|zh|>`(24884) `<|en|>`(24885) … ; task tags `<|ASR|>`(24989) `<|AED|>`(24990)
  `<|SER|>`(24991) `<|nospeech|>`(24992); event tags `<|Speech|>`/`<|BGM|>`/`<|Laughter|>`/…;
  emotion tags `<|HAPPY|>`(25001)…`<|EMO_UNKNOWN|>`(25009); itn tags `<|withitn|>`(25016)
  `<|woitn|>`(25017). Decoder must drop every `<|...|>` token and convert SPM `▁` to a space.

## Frontend (for FbankExtractor — Task 3)

Produced via funasr `WavFrontend` with SenseVoice params: `fs=16000, n_mels=80,
frame_length=25ms, frame_shift=10ms, window=hamming, lfr_m=7, lfr_n=6, dither=0, cmvn_file=am.mvn`.
Output per frame is 560-dim (80 mel × 7 LFR stack), CMVN-normalized. This matches the values
already in `SenseVoiceConfig.swift` (melBins=80, frame 25/10ms, lfrM=7, lfrN=6).

**Amplitude scale (critical):** funasr `WavFrontend` (`upsacle_samples=True`) applies a
**single `waveform * (1 << 15)`** to the **[-1,1]** float waveform before `kaldi.fbank`. funasr's
audio loaders (and KeyMic's live mic / `AVAudioFile` path) both yield [-1,1] samples, so the
correct multiplier is **2^15, applied once**. The bundled `am.mvn` CMVN stats are computed at this
2^15 scale, so `FbankExtractor.sampleScale` MUST be `1 << 15`. (Historical note: an earlier golden
was mistakenly generated at **2^30** — the export pre-scaled the wav to int16 range and then
`WavFrontend` multiplied by 2^15 again. That double scale adds a uniform `2·ln(2^15) ≈ 20.7944`
offset to every pre-CMVN log-mel bin, which post-CMVN re-centers features near **+3** instead of
**~0** → out-of-distribution input → garbled transcription. Fixed: scale is 2^15, golden
regenerated.)

`am.mvn` is the kaldi CMVN text: `<AddShift>` (negated mean, 560 dims) + `<Rescale>`
(inverse std, 560 dims); the 80-dim mel stats are tiled 7× across the LFR window.
`am.mvn` SHA256 = `29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5` (11203 bytes).

## Golden fixtures (Tests/Support/sensevoice/)

| file | what | how |
| --- | --- | --- |
| `hello_16k.wav` | 16 kHz mono ~2 s | **SYNTHETIC** deterministic tone+sweep (seed 42), NOT real speech. No real zh/en sample was available offline. |
| `hello_fbank.json` | `[33][560]` LFR-fbank | funasr `WavFrontend` (params above, **single 2^15 scale** on the [-1,1] wav) on `hello_16k.wav`. Use for FbankExtractor (T3) golden test — note the synthetic input means values are golden-against-funasr, not against real speech. frame0 post-CMVN ≈ `[-0.32, -0.13, -0.40, ...]` (centered near 0, confirming the correct 2^15 scale). |
| `sample_ids.json` | per-frame argmax + collapsed ids/tokens | greedy argmax of the REAL `.mlmodelc` `ctc_logits` on `hello_fbank.json`. Use for CTCDecoder (T5) golden test. |
| `sample_expected.txt` | empty | the synthetic WAV decodes to `<|nospeech|><|EMO_UNKNOWN|><|Event_UNK|><|woitn|>` → empty after tag-strip. CAVEAT: an empty expected string is a weak golden for the decoder; replace with a real-speech sample later for a stronger T5 assertion. |

The full `[37][25055]` float logits matrix (~10 MB) was generated and verified but **not
committed** (too large for a fixture). Only the compact per-frame argmax (`sample_ids.json`) is
committed — that is exactly what a greedy CTC decoder consumes.

## Environment probe summary (Task 0)

- python3 = 3.9.6 (/usr/bin/python3, system). No coremltools/torch/funasr/onnx/numpy preinstalled.
- network: github.com reachable; huggingface.co HTTP/2 200.
- venv at `/tmp/sv-spike/venv`: installed `coremltools 9.0`, `sentencepiece 0.2.1`,
  `numpy 1.26.4`, `protobuf 6.33.6`, and (for golden export) `torch 2.3.1` + `torchaudio` +
  `funasr 1.3.9`. All on py3.9.
- `swift`/`swiftc`/`xcrun` available — used to load `.mlmodelc` and run the forward pass since
  coremltools cannot open a bare compiled `.mlmodelc`.
