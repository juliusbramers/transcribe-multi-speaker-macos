# Models

Every model tmsm can run, the four presets built from them, and where each comes from.
The preset table in code is `Sources/TMSM/Catalogue/Presets.swift`; this page follows it.

All models download from Hugging Face on first use, into `TMSM_HOME/models/<engine>/`
(default `~/Library/Application Support/tmsm/models/`). None needs a token.

## Presets

| Preset | Speech to text | Word timings | Speakers (max 4) | Peak RAM, measured | Download | Languages |
|---|---|---|---|---:|---:|---|
| fast | Parakeet TDT 0.6B v3 | Parakeet (built in) | Nemotron-3, c128-split-w8a8 | 0.4 GB | ~0.6 GB | 25 |
| default | Parakeet Ultra | Parakeet (built in) | Nemotron-3, offline | 0.4 GB | ~0.8 GB | 25 |
| accurate | Qwen3-ASR 1.7B, 8-bit | Qwen3 forced aligner 0.6B, 8-bit | Nemotron-3, offline | 3.4–5.6 GB | ~3.8 GB | 28 + auto-detect |
| extreme | best measured model per language (routing table) | Qwen3 forced aligner 0.6B, 8-bit | Nemotron-3, offline | 5.5–5.7 GB | see routing | 28 + auto-detect |

extreme's routing is still a stub: every language goes to Qwen3-ASR 1.7B 8-bit until the
bake-off settles the table. Its row will change with it.

**How RAM was measured:** peak memory footprint from `/usr/bin/time -l` for a whole `tmsm`
run (decode, transcribe, align, speakers), on an M2 Max with 32 GB. The range spans a 10 s clip
to a 30-minute meeting (AMI EN2002a). Footprint includes MLX's GPU buffers; resident set size
under-counts them (accurate on 30 min: 2.7 GB RSS, 5.6 GB footprint). fast and default figures
are from the bake-off (session D), same file.

**How long files are handled (MLX presets):** the audio is cut into windows of at most 25 s,
each cut at the quietest point within its last 5 s, so nothing is dropped. The speech model
transcribes each window, is released, and the aligner then times each window's words. Only one
model is in memory at a time. On AMI EN2002a (30 min, far-field, 4 speakers) accurate scores
33.8 % WER against the manual word annotations (bake-off normaliser), against 45.8 % for
speech-swift's VAD-segmented streaming.

**Language:** `--language de` sets the language; without it, Qwen3-ASR detects it. extreme
detects it from the first minute and then runs the model its routing table names for it.

## Catalogue

| Id | Model | Engine | Hugging Face repo | Download | Languages | Licence |
|---|---|---|---|---:|---|---|
| parakeet-v3 | Parakeet TDT 0.6B v3 (Core ML) | FluidAudio | FluidInference/parakeet-tdt-0.6b-v3-coreml | ~480 MB | 25 | CC-BY-4.0 |
| parakeet-ultra | Parakeet Ultra (Core ML) | FluidAudio | FluidInference/parakeet-ultra-coreml | ~630 MB | 25 | CC-BY-4.0 |
| nemotron3-c128-split-w8a8 | Nemotron-3 Diarization, c128-split-w8a8 | FluidAudio | FluidInference/nemotron-3-diarization-coreml | ~95 MB | any | OpenMDW-1.1 |
| nemotron3-offline | Nemotron-3 Diarization, offline | FluidAudio | FluidInference/nemotron-3-diarization-coreml | ~190 MB | any | OpenMDW-1.1 |
| qwen3-asr-1.7b-8bit | Qwen3-ASR 1.7B, 8-bit (MLX) | speech-swift | aufklarer/Qwen3-ASR-1.7B-MLX-8bit | 2.35 GB | 28 | Apache-2.0 |
| qwen3-asr-1.7b-5bit | Qwen3-ASR 1.7B, 5-bit (MLX) | speech-swift | aufklarer/Qwen3-ASR-1.7B-MLX-5bit | 2.33 GB | 28 | Apache-2.0 ¹ |
| voxtral-mini-3b-8bit | Voxtral Mini 3B 2507, 8-bit (MLX) | speech-swift | aufklarer/Voxtral-Mini-3B-2507-MLX-8bit | 5.58 GB | 8 | Apache-2.0 |
| (used by every MLX entry) | Qwen3 forced aligner 0.6B, 8-bit (MLX) | speech-swift | aufklarer/Qwen3-ForcedAligner-0.6B-8bit | 1.22 GB | 11 ² | Apache-2.0 |
| extreme-routed | runs the entry extreme's routing table names | — | — | sum of routed | union | per routed model |

MLX download sizes are measured on disk. Each MLX speech entry also needs the aligner, so
setup's figure for it is model + 1.22 GB. Peak RAM per model, from the bake-off (30-minute file,
one process per stage, footprint): Qwen3-ASR 8-bit 4.75 GB, 5-bit 3.3 GB, Voxtral Mini 8-bit
7.4 GB, Nemotron-3 offline 0.4 GB. A whole tmsm run with Voxtral Mini 8-bit (windows, aligner,
Nemotron-3 offline) peaked at 8.2 GB on the same file.

¹ The 5-bit repo's card names no licence; it is a conversion of Qwen/Qwen3-ASR-1.7B
(Apache-2.0).
² The aligner times words in any language Qwen3-ASR writes; it splits words with spaces, or with
Apple's tokenizer for Japanese, Korean, Thai, Lao, Khmer, Burmese and Tibetan.

**Languages**

- Parakeet v3 and Ultra (25): bg, cs, da, de, el, en, es, et, fi, fr, hr, hu, it, lt, lv, mt, nl,
  pl, pt, ro, ru, sk, sl, sv, uk.
- Qwen3-ASR 1.7B (30; the 28 with an ISO 639-1 code are selectable): ar, cs, da, de, el, en, es,
  fa, fi, fr, hi, hu, id, it, ja, ko, mk, ms, nl, pl, pt, ro, ru, sv, th, tr, vi, zh, plus
  Cantonese and Filipino by auto-detection.
- Voxtral Mini (8): de, en, es, fr, hi, it, nl, pt; detects the language when none is given.

## Evaluated, not shipped

- **Cohere Transcribe 2B** (CohereLabs/cohere-transcribe-03-2026, Apache-2.0), MLX fp16 and
  Core ML int8. Good on read speech (FLEURS de/en 3.93/4.55 % WER), but on conversation it
  stops at end-of-sequence early in every window and so drops quieter, non-dominant speakers
  (AMI EN2002a, 30 min: 46.5 % WER, about 40 % of words missing). This happens in both ports,
  so it is the model, not the integration. speech-swift's default MLX path can also loop
  ("for the" ×170) with no repetition guard. Offering it, even under `individual`, would give
  broken transcripts. (Bake-off, session D, 2026-11-08.)
- **Qwen3-ASR 1.7B at full precision**: not available in speech-swift 0.0.29, whose loader
  always quantises the decoder. 8-bit and 5-bit were measured instead.

## Runtimes

- **FluidAudio** 0.18.2 (Apache-2.0, FluidInference): Core ML on the Neural Engine and GPU.
- **speech-swift** 0.0.29 (Apache-2.0, soniqo): MLX on the GPU. tmsm uses only its Qwen3ASR,
  VoxtralASR and AudioCommon modules.
- **MLX Swift** (MIT, ml-explore): needs `mlx.metallib` next to the `tmsm` binary;
  `scripts/build-metallib.sh` builds it.

## Credits

- Parakeet TDT 0.6B v3: NVIDIA (nvidia/parakeet-tdt-0.6b-v3); Core ML conversion by
  FluidInference.
- Parakeet Ultra: moondream (moondream/parakeet-ultra); Core ML conversion by FluidInference.
- Nemotron-3 Diarization: NVIDIA (nvidia/Nemotron-3-Diarization); Core ML conversion by
  FluidInference.
- Qwen3-ASR 1.7B and Qwen3-ForcedAligner 0.6B: Qwen team, Alibaba (Qwen/Qwen3-ASR-1.7B,
  Qwen/Qwen3-ForcedAligner-0.6B); MLX conversions by aufklarer.
- Voxtral Mini 3B 2507: Mistral AI (mistralai/Voxtral-Mini-3B-2507); MLX conversion by
  aufklarer.
