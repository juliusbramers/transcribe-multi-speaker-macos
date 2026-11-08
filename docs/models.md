# Models

Every model tmsm can run, the four presets built from them, and where each comes from.
The preset table in code is `Sources/TMSM/Catalogue/Presets.swift`; this page follows it.

All models download from Hugging Face on first use, into `TMSM_HOME/models/<engine>/`
(default `~/Library/Application Support/tmsm/models/`). None needs a token.

## Presets

Every preset labels speakers with Nemotron-3 offline (at most 4, numbered by first appearance)
and picks its speech model by the file's language. None loads the forced aligner: Parakeet has
its own word timings (measured as good as the aligner's), and in turn-wise decoding every word
takes its turn's speaker, so Qwen3-ASR's words need no exact times. The aligner is used when an
MLX model transcribes a whole file in windows (`individual`).

| Preset | en, de | other Qwen3-ASR languages | other Parakeet Ultra languages | Peak RAM, measured |
|---|---|---|---|---:|
| fast | Ultra, windows | Qwen3-ASR 1.7B 8-bit, turn-wise ¹ | Ultra, windows | 0.4 GB ² |
| default | Ultra, turn-wise | Qwen3-ASR 1.7B 8-bit, turn-wise ¹ | Ultra, turn-wise | 0.4 GB ² |
| accurate | Ultra, turn-wise | Qwen3-ASR 1.7B 8-bit, turn-wise | Ultra, turn-wise | 0.4–6.2 GB ³ |
| extreme | same as accurate | same as accurate | same as accurate | 0.4–6.2 GB ³ |

extreme is currently identical to accurate: no larger pipeline measured better with the v0.1.0
engines (bake-off, session D: a three-system vote and the aligner gave no gain).

A language no route supports is an error that names `--language` and lists the supported
languages; tmsm never substitutes one silently.

¹ A note on stderr says the run is slower and needs about 6 GB.
² Ultra and Nemotron only. Outside Ultra's languages, as accurate.
³ 0.4 GB with `--language`. Without it, accurate detects the language with Qwen3-ASR (3.9–6.2
GB; the top is the first run, which also checks the model files' hashes), then runs Ultra for
en/de.

**Strategies.**
- *windows*: the whole file is transcribed, speakers are labelled, and each word takes the speaker
  whose segments overlap it most.
- *turn-wise*: speakers are labelled first, the file is cut into speaker turns covering all of it
  (overlap goes to whoever started speaking last, pauses split between neighbours), long turns are
  split at quiet points at most 25 s apart, and each turn is transcribed on its own. Every word
  takes its turn's speaker. On held-out AMI meetings this gave the lowest speaker-attributed error
  (cpWER: turn-wise Ultra 18.7 %, Ultra on windows 20.4 %, turn-wise Qwen3 20.6 %, Voxtral
  25.3 %; bake-off, session D).

**Language.** `--language` wins. Otherwise the language is detected once per file from up to
three windows of speech (about a minute), with Apple's language recogniser constrained to the
detecting model's languages, and that language is passed to every window or turn. Qwen3-ASR
left to detect per turn emitted Chinese on about 18 % of English turns, so it is never run
without a language. fast and default detect with Ultra and fall back to Qwen3-ASR when unsure;
accurate and extreme detect with Qwen3-ASR. When no detector is sure, English is used and a note
says so.

**Determinism.** Decoding is greedy everywhere; the same audio and preset give byte-identical
Markdown (checked: accurate twice on an 8.4-minute German recording).

**Measurements** (M2 Max, 32 GB, debug build, peak footprint from `/usr/bin/time -l`; footprint
includes MLX's GPU buffers, which resident set size under-counts):

| Run | Time | Peak | Speakers | WER ⁴ |
|---|---:|---:|---:|---:|
| default, AMI EN2002a 30 min (en) | 60 s | 0.40 GB | 4 | 35.0 % |
| accurate, 8.4 min German meeting (detected de) | 33 s | 5.1 GB | 2 | — |
| accurate, 10 s German clip (detected de), first run with hash check | 17 s | 6.2 GB | 2 | — |
| accurate, same clip, network blocked | 4 s | 3.9 GB | 2 | — |
| accurate, FLEURS single speaker (de) | 4 s | 4.3 GB | 1 | — |
| Qwen3-ASR 1.7B 8-bit, windows + aligner, EN2002a 30 min | 285 s | 5.6 GB | 4 | 33.8 % |
| Voxtral Mini 8-bit, windows + aligner, EN2002a 30 min | 248 s | 8.2 GB | 4 | 40.9 % |

⁴ Plain WER against the AMI word annotations of all speakers merged by start time (bake-off
normaliser). Overlapping speech makes that merged order ambiguous, so it penalises turn-wise
output; the speaker-attributed cpWER above is the measure the presets were chosen by.

**Pinned models.** Every model is pinned to one Hugging Face commit. MLX models: tmsm downloads
each file from that commit and checks its SHA-256 before use; a complete, marked folder is used
without the network. FluidAudio models: pinned through FluidAudio's revision setting, which marks
the folder and checks file sizes and Core ML bundle completeness, not hashes.

| Repo | Commit |
|---|---|
| aufklarer/Qwen3-ASR-1.7B-MLX-8bit | e5450a26d1fd417c45fc9c405651ddc3180a27a6 |
| aufklarer/Qwen3-ASR-1.7B-MLX-5bit | 1645ca9ce8767dac9a4a047e9de835950c42596e |
| aufklarer/Voxtral-Mini-3B-2507-MLX-8bit | fd378a44090b8b06fdb9f415896e4672edb02ecf |
| aufklarer/Qwen3-ForcedAligner-0.6B-8bit | 0457b7f546f629bacd1671d57252f1c561347bcb |
| FluidInference/parakeet-tdt-0.6b-v3-coreml | 7dd20fe6b1797d35f5e3307e8b1732d9a178edfe |
| FluidInference/parakeet-ultra-coreml | 95eaa59a39d4394f047a4dc5cce480388a60d1b6 |
| FluidInference/nemotron-3-diarization-coreml | 25a90f97f254428d4b30374b76af9c74fdee8327 |

## Catalogue

| Id | Model | Engine | Hugging Face repo | Download | Languages | Licence |
|---|---|---|---|---:|---|---|
| parakeet-v3 | Parakeet TDT 0.6B v3 (Core ML) | FluidAudio | FluidInference/parakeet-tdt-0.6b-v3-coreml | ~480 MB | 25 | CC-BY-4.0 |
| parakeet-ultra | Parakeet Ultra (Core ML) | FluidAudio | FluidInference/parakeet-ultra-coreml | ~630 MB | 25 | CC-BY-4.0 |
| nemotron3-c128-split-w8a8 | Nemotron-3 Diarization, c128-split-w8a8 | FluidAudio | FluidInference/nemotron-3-diarization-coreml | ~95 MB | any | OpenMDW-1.1 |
| nemotron3-offline | Nemotron-3 Diarization, offline | FluidAudio | FluidInference/nemotron-3-diarization-coreml | ~190 MB | any | OpenMDW-1.1 |
| qwen3-asr-1.7b-8bit | Qwen3-ASR 1.7B, 8-bit (MLX) | speech-swift | aufklarer/Qwen3-ASR-1.7B-MLX-8bit | 2.35 GB | 28 | Apache-2.0 |
| qwen3-asr-1.7b-5bit | Qwen3-ASR 1.7B, 5-bit (MLX) | speech-swift | aufklarer/Qwen3-ASR-1.7B-MLX-5bit | 2.33 GB | 28 | Apache-2.0 ⁵ |
| voxtral-mini-3b-8bit | Voxtral Mini 3B 2507, 8-bit (MLX) | speech-swift | aufklarer/Voxtral-Mini-3B-2507-MLX-8bit | 5.58 GB | 8 | Apache-2.0 |
| (used by every MLX entry) | Qwen3 forced aligner 0.6B, 8-bit (MLX) | speech-swift | aufklarer/Qwen3-ForcedAligner-0.6B-8bit | 1.22 GB | 11 ⁶ | Apache-2.0 |

MLX download sizes are measured on disk. Each MLX speech entry also needs the aligner, so
setup's figure for it is model + 1.22 GB. Peak RAM per model, from the bake-off (30-minute file,
one process per stage, footprint): Qwen3-ASR 8-bit 4.75 GB, 5-bit 3.3 GB, Voxtral Mini 8-bit
7.4 GB, Nemotron-3 offline 0.4 GB. A whole tmsm run with Voxtral Mini 8-bit (windows, aligner,
Nemotron-3 offline) peaked at 8.2 GB on the same file.

⁵ The 5-bit repo's card names no licence; it is a conversion of Qwen/Qwen3-ASR-1.7B
(Apache-2.0).
⁶ The aligner times words in any language Qwen3-ASR writes; it splits words with spaces, or with
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
