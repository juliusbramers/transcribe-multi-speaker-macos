# Models

Every model tmsm can run, the four presets built from them, and where each comes from.
The preset table in code is `Sources/TMSM/Catalogue/Presets.swift`; this page follows it.

All models download from Hugging Face on first use, into `TMSM_HOME/models/<engine>/`
(default `~/Library/Application Support/tmsm/models/`). None needs a token.

## Presets

Every preset picks its speech model by the file's language. Speakers are numbered by first
appearance, at most 4 (`--speakers`); `--speakers none` runs no speaker model and writes plain
paragraphs.

| Preset | en, de and the other Parakeet languages | other Qwen3-ASR languages | Peak RAM, measured |
|---|---|---|---:|
| fast | Ultra, windows, no speaker model by default | Qwen3-ASR 1.7B 8-bit, turn-wise ¹ | 0.4 GB |
| default | Ultra, windows + Nemotron-3 offline, words by overlap | Qwen3-ASR 1.7B 8-bit, turn-wise ¹ | 0.4 GB |
| accurate | Nemotron-3 offline, then Ultra turn by turn | Qwen3-ASR 1.7B 8-bit, turn-wise ¹ | 0.4 GB (6.2 with Qwen3) |
| extreme | MOSS-Transcribe-Diarize cuts the turns, Ultra decodes them | MOSS alone (its languages) ², else as accurate | 9.7 GB at 38 min ³ |

A language no route supports is an error that names `--language` and lists the supported
languages; tmsm never substitutes one silently.

¹ A note on stderr says the run is slower and needs about 6 GB.
² MOSS's card names these: de, en, es, fr, it, ja, ko, pt, ru, th, tr, ur, vi, zh. Languages
Parakeet covers get Ultra's words on MOSS's turns; the rest keep MOSS's words.
³ MOSS holds the whole recording in its context: memory grows with length (about 114 KB per
token, 12.5 audio tokens per second plus the transcript). It runs on recordings up to 60 min
(estimated 14 GB at the top); longer recordings, and recordings MOSS does not finish (its decoder
stops early, writes no segments for audible audio, or leaves audible speech of 45 s or more
without a segment), fall back to the accurate pipeline with a note on stderr and a `fallback`
field in `--json`. The int8 key/value cache was tried on the 38-min file: 0.7 GB less, 2.5× the
time, and the speakers collapsed from 68 turns to 17, so it is not used.

**Strategies.**
- *windows*: the whole file is transcribed in Parakeet's own long-form windows, speakers are
  labelled, the speaker segments are cleaned (same-speaker gaps under 0.5 s merge; a fragment
  under 1 s that another speaker talks over or around is activity, not a turn), and each word
  takes the speaker whose segments overlap it most. A run of at most two words (under 0.6 s,
  pauses of at most 0.5 s around it) inside another speaker's flow joins that flow when the
  flowing speaker's segments overlap it too.
- *turn-wise*: speakers are labelled first and cleaned the same way, the file is cut into speaker
  turns covering all of it (overlap goes to the longer segment, pauses split between neighbours,
  each cut moves to a pause within 0.3 s when there is one), long turns are split at quiet points
  at most 25 s apart, and each turn is transcribed on its own with 0.3 s of context on both
  sides. A word belongs to the turn its middle falls in. Every word takes its turn's speaker.
  Qwen3-ASR turns have no word times and are decoded without context.
- *joint*: MOSS-Transcribe-Diarize decodes the whole recording in one context and writes
  timestamped segments with speaker labels. Its segments become the speaker turns; where a speech
  model with better spelling covers the language (Ultra), it decodes those turns as above.

**Why these tiers** (2026-11-08/09, M2 Max 32 GB; a 38-min German two-speaker conversation
with a cloud provider's transcript as text reference, and three held-out AMI excerpts of 4 min
with 4 speakers each, from the v1 bake-off):

| Pipeline | turns on the 38-min file | turns ≤3 words | WER vs cloud text ⁴ | AMI cpWER ⁵ | time | peak RAM |
|---|---:|---:|---:|---:|---:|---:|
| v0.1.0 default/accurate (Ultra turn-wise, raw Nemotron turns) | 460 | 202 | 25.9 % | AMI_OLD_ACC | 55 s | 0.5 GB |
| default (Ultra windows + cleaned Nemotron) | 126 | 15 | 20.3 % | AMI_DEFAULT | 55 s | 0.5 GB |
| accurate (cleaned Nemotron turns, Ultra with context) | 120 | 18 | 20.5 % | AMI_ACCURATE | 67 s | 0.4 GB |
| Qwen3-ASR 1.7B 8-bit, windows + aligner | 288 | 105 | QWEN_WER | — | 197 s | 6.2 GB |
| MOSS alone (words and turns) | 68 | 1 | 28.1 % | — | 398 s | 9.6 GB |
| extreme (MOSS turns, Ultra words) | 66 | 1 | 20.7 % | AMI_EXTREME | 636 s | 9.7 GB |

The v0.1.0 turn-wise pipeline decoded every sub-second listener fragment on its own and
Parakeet answered with English fillers ("Yeah.", "Thank you.": about 100 of them). The cloud
transcript has 22 turns and over-merges speakers, so WER against it measures agreement on the
words, not attribution. Ultra's words agree best with it; Qwen3 and MOSS spell proper nouns
better (Palantir, Pain Point) but disagree more overall. These are development recordings, not
fresh human references; see `notes/` in the workspace for the full analysis.

⁴ Normalised: NFKC, casefold, punctuation removed (the bake-off's normaliser).
⁵ Speaker-attributed WER on ES2004b, IS1009b and TS3003b, 300–540 s, English, 4 speakers,
`--speakers 4 --language en`, pooled over the three.

**Language.** `--language` wins. Otherwise the language is detected once per file from up to
three windows of speech (about a minute), and that language is passed to every window or turn.
Qwen3-ASR left to detect per turn emitted Chinese on about 18 % of English turns, so it is never
run without a language. A detecting model transcribes the sample, and Apple's language
recogniser reads that text against every language it knows, not only the preset's. So a
language no route covers comes out as itself. Every preset detects with Ultra and goes on to
Qwen3-ASR when Ultra is unsure or hears a language it can't write. A language the preset doesn't
cover, or speech no detector is sure of, is an error that asks for `--language` and lists the
supported codes. tmsm never guesses English. A recording with no speech gives an empty
transcript.

**Qwen3-ASR decoding.** speech-swift masks repeated trigrams on windows over 15 s by default;
that rewrote natural repeats ("du möchtest … du möchtest" → "möchtes"), so tmsm turns it off and
instead redoes a window once with a repetition penalty of 1.1 when its text loops (a run of one
to three words repeated four times). Its `context` prompt made spelling and punctuation worse on
German speech and is not used.

**Determinism.** Decoding is greedy everywhere; the same audio and preset give byte-identical
Markdown (checked: accurate twice on an 8.4-minute German recording; v0.1.0 accurate twice on the
38-minute one).

**Pinned models.** Every model is pinned to one Hugging Face commit. MLX models: tmsm downloads
each file from that commit and checks its SHA-256 before use; a complete, marked folder is used
without the network. FluidAudio models: pinned through FluidAudio's revision setting, which marks
the folder and checks file sizes and Core ML bundle completeness, not hashes.

| Repo | Commit |
|---|---|
| aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8 | 90aa65287111a327db98eb83e325bd5332945edd |
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
| moss-transcribe-diarize-0.9b-8bit | MOSS-Transcribe-Diarize 0.9B, int8 decoder (MLX); words and speakers from one model | speech-swift | aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8 | 1.27 GB | 14 named ⁶ | Apache-2.0 |
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

⁶ Upstream claims 50+ languages without listing them; tmsm routes the 14 its card names.

**Languages**

- Parakeet v3 and Ultra (25): bg, cs, da, de, el, en, es, et, fi, fr, hr, hu, it, lt, lv, mt, nl,
  pl, pt, ro, ru, sk, sl, sv, uk.
- Qwen3-ASR 1.7B (30; the 28 with an ISO 639-1 code are selectable): ar, cs, da, de, el, en, es,
  fa, fi, fr, hi, hu, id, it, ja, ko, mk, ms, nl, pl, pt, ro, ru, sv, th, tr, vi, zh, plus
  Cantonese and Filipino by auto-detection.
- Voxtral Mini (8): de, en, es, fr, hi, it, nl, pt; detects the language when none is given.
- MOSS-Transcribe-Diarize (14 named): de, en, es, fr, it, ja, ko, pt, ru, th, tr, ur, vi, zh.

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
- **speech-swift** 0.0.29 (Apache-2.0, soniqo): MLX on the GPU. tmsm uses only its Qwen3ASR, MossTranscribe,
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
- MOSS-Transcribe-Diarize: OpenMOSS team (OpenMOSS-Team/MOSS-Transcribe-Diarize); MLX
  conversion by aufklarer.
