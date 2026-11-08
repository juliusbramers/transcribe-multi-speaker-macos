import Foundation
import Synchronization

@testable import TMSM

/// Session B: MLX presets, the preset table, windows, word timings and language routing.
enum MLXCases {
  static func run(_ t: Runner) {
    presetTable(t)
    windows(t)
    wordTimings(t)
    routing(t)
    turnwise(t)
    if ProcessInfo.processInfo.environment["TMSM_SELFTEST_PREPARE"] == "1" { prepare(t) }
    if let clip = ProcessInfo.processInfo.environment["TMSM_SELFTEST_DETERMINISM"] {
      determinism(t, clip: clip)
    }
    if let probe = ProcessInfo.processInfo.environment["TMSM_SELFTEST_PROBE"] {
      self.probe(t, probe)
    }
  }

  /// Opt-in measurement: `TMSM_SELFTEST_PROBE=<entry id>:<file>:<output folder>[:turnwise]`
  /// runs a full pipeline with that transcription entry and Nemotron-3 offline, for entries and
  /// strategies no preset uses yet.
  static func probe(_ t: Runner, _ spec: String) {
    let parts = spec.split(separator: ":", maxSplits: 3).map(String.init)
    guard parts.count >= 3 else { return t.test("probe") { t.expect(false, "bad probe spec") } }
    let home = TMSMHome.resolve()
    let preset = Preset(
      name: "probe", transcription: parts[0], speakers: "nemotron3-offline", summary: "",
      ramGB: nil, strategy: parts.count > 3 && parts[3] == "turnwise" ? .turnwise : .windows)
    let catalogue = Catalogue(Catalogue.registrations, presets: [preset])
    let done = DispatchSemaphore(value: 0)
    let outcome = Mutex<Result<RunResult, any Error>?>(nil)
    Task {
      do {
        let runTemp = try home.activate()
        defer { home.removeRunTemporary(runTemp) }
        let options = try RunOptions.parse([parts[1], "--preset", "probe", "--output", parts[2]])
        let result = try await Pipeline(home: home, catalogue: catalogue).run(
          options, progress: .silent)
        outcome.withLock { $0 = .success(result) }
      } catch { outcome.withLock { $0 = .failure(error) } }
      done.signal()
    }
    done.wait()
    t.test("probe: \(parts[0]) runs end to end") {
      let result = try outcome.withLock { $0 }!.get()
      print(result.json)
      t.expect(result.words > 0, "words")
    }
  }

  /// Opt-in, needs the accurate models in TMSM_HOME: two runs on the same clip must give
  /// byte-identical Markdown.
  static func determinism(_ t: Runner, clip: String) {
    let home = TMSMHome.resolve()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmsm-determinism-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let done = DispatchSemaphore(value: 0)
    let outcome = Mutex<Result<[Data], any Error>?>(nil)
    Task {
      do {
        var texts: [Data] = []
        for name in ["a.md", "b.md"] {
          let runTemp = try home.activate()
          defer { home.removeRunTemporary(runTemp) }
          let options = try RunOptions.parse([
            clip, "--preset", "accurate", "--output", dir.appendingPathComponent(name).path,
            "--quiet",
          ])
          let result = try await Pipeline(home: home).run(options, progress: .silent)
          texts.append(try Data(contentsOf: URL(fileURLWithPath: result.output)))
        }
        outcome.withLock { $0 = .success(texts) }
      } catch { outcome.withLock { $0 = .failure(error) } }
      done.signal()
    }
    done.wait()
    t.test("determinism: accurate twice on one clip gives byte-identical Markdown") {
      let texts = try outcome.withLock { $0 }!.get()
      t.expect(texts.count, 2)
      t.expect(texts[0] == texts[1], "the two transcripts differ")
      t.expect(!texts[0].isEmpty, "a transcript")
    }
  }

  /// Opt-in, needs the network: prepares every preset's entries into TMSM_HOME.
  static func prepare(_ t: Runner) {
    let home = TMSMHome.resolve()
    let done = DispatchSemaphore(value: 0)
    let failure = Mutex<String?>(nil)
    Task {
      do {
        try home.activate()
        for p in Catalogue.shared.presets {
          for id in p.entries {
            try await Catalogue.shared.entry(id).prepare(home, .silent)
          }
        }
      } catch { failure.withLock { $0 = "\(error)" } }
      done.signal()
    }
    done.wait()
    t.test("prepare: every preset's models download without running") {
      t.expect(failure.withLock { $0 } == nil, "prepare failed: \(failure.withLock { $0 } ?? "")")
      let used = Set(Catalogue.shared.presets.flatMap(\.entries))
      for spec in MLXEngine.transcribers where used.contains(spec.id) {
        t.expect(MLXEngine.isDownloaded(spec.model, home), "\(spec.id) complete and pinned")
      }
      t.expect(MLXEngine.isDownloaded(MLXEngine.aligner, home), "aligner complete and pinned")
    }
  }

  static func presetTable(_ t: Runner) {
    t.test("presets: every preset resolves to token-free entries of the right kind") {
      let cat = Catalogue.shared
      t.expect(cat.presetNames, ["fast", "default", "accurate", "extreme"])
      for p in cat.presets {
        let asr = try cat.entry(p.transcription)
        let spk = try cat.entry(p.speakers)
        t.expect(asr.kind, .transcription, p.name)
        t.expect(spk.kind, .speakers, p.name)
        t.expect(!asr.gated && !spk.gated, "\(p.name) needs no token")
        for id in p.routing?.entries ?? [] {
          t.expect(try cat.entry(id).kind, .transcription, "\(p.name) routes to \(id)")
          t.expect(!(try cat.entry(id).gated), "\(id) needs no token")
        }
      }
    }

    t.test("presets: the v0.1.0 mapping") {
      let cat = Catalogue.shared
      func pick(_ preset: String, _ language: String) throws -> String {
        let (route, entry) = try PresetRouting.route(
          cat.preset(named: preset), language: language, catalogue: cat)
        return "\(entry.id)/\(route?.strategy.rawValue ?? "-")"
      }
      t.expect(try pick("fast", "de"), "parakeet-ultra/windows")
      t.expect(try pick("fast", "ja"), "qwen3-asr-1.7b-8bit/turnwise")
      t.expect(try pick("default", "en"), "parakeet-ultra/turnwise")
      t.expect(try pick("default", "zh"), "qwen3-asr-1.7b-8bit/turnwise")
      for preset in ["accurate", "extreme"] {
        t.expect(try pick(preset, "en"), "parakeet-ultra/turnwise", preset)
        t.expect(try pick(preset, "de"), "parakeet-ultra/turnwise", preset)
        t.expect(try pick(preset, "fr"), "qwen3-asr-1.7b-8bit/turnwise", "\(preset) fr → Qwen3")
        t.expect(try pick(preset, "hr"), "parakeet-ultra/turnwise", "\(preset) hr → Ultra only")
      }
      t.expect(cat.presets.allSatisfy { $0.speakers == "nemotron3-offline" }, "Nemotron offline")
      t.expect(
        cat.presets.allSatisfy { $0.ramGB.map { $0.lowerBound > 0 } ?? true }, "RAM > 0")
    }

    t.test("presets: a language no route supports is an error naming --language") {
      do {
        _ = try PresetRouting.route(
          Catalogue.shared.preset(named: "accurate"), language: "sw", catalogue: .shared)
        t.expect(false, "expected an error")
      } catch {
        let message = error.localizedDescription
        t.expect(message.contains("--language"), "names --language: \(message)")
        t.expect(message.contains("de") && message.contains("ja"), "lists the languages")
      }
    }

    t.test("presets: entries lists everything setup must download") {
      let p = try Catalogue.shared.preset(named: "default")
      t.expect(p.entries, ["parakeet-ultra", "qwen3-asr-1.7b-8bit", "nemotron3-offline"])
    }

    t.test("presets: extreme says it is accurate for now") {
      let e = try Catalogue.shared.preset(named: "extreme")
      let a = try Catalogue.shared.preset(named: "accurate")
      t.expect(e.routing, a.routing)
      t.expect(e.summary.hasPrefix("Currently identical to accurate"), "honest summary")
    }

    t.test("mlx: models live under models/mlx/<org>/<name>") {
      let home = TMSMHome(root: URL(fileURLWithPath: "/r"))
      let entry = try Catalogue.shared.entry("qwen3-asr-1.7b-8bit")
      t.expect(
        entry.storage(home).map(\.path),
        [
          "/r/models/mlx/aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
          "/r/models/mlx/aufklarer/Qwen3-ForcedAligner-0.6B-8bit",
        ])
    }
  }

  static func windows(_ t: Runner) {
    let sr = 100  // 100 "samples" per second keeps the arithmetic readable
    t.test("windows: short audio is one window, empty audio none") {
      t.expect(Chunking.plan(sampleCount: 0, sampleRate: sr) { _ in 1 }, [])
      t.expect(Chunking.plan(sampleCount: 2500, sampleRate: sr) { _ in 1 }, [0..<2500])
    }

    t.test("windows: cover the audio exactly, each at most 25 s, cut at the quiet point") {
      // Quiet at 22 s and again at 44 s (relative to the second window's start).
      let quiet: Set<Int> = [2200, 4400]
      let ranges = Chunking.plan(sampleCount: 7000, sampleRate: sr) { r in
        quiet.contains(r.lowerBound) ? 0 : 1
      }
      t.expect(ranges.first?.lowerBound, 0)
      t.expect(ranges.last?.upperBound, 7000)
      for (a, b) in zip(ranges, ranges.dropFirst()) {
        t.expect(a.upperBound, b.lowerBound, "no gap or overlap")
      }
      t.expect(ranges.allSatisfy { $0.count <= 2500 }, "at most 25 s")
      t.expect(ranges[0].upperBound, 2205, "first cut in the quiet window's middle")
      t.expect(ranges[1].upperBound, 4405, "second cut in the quiet window's middle")
    }

    t.test("windows: energy is mean square") {
      t.expect(Chunking.meanSquare([1, -1, 0, 0], 0..<4), 0.5)
      t.expect(Chunking.meanSquare([1], 0..<0), 0)
    }
  }

  /// Aligned words → tmsm words, through the same two steps the engine uses.
  static func place(
    _ aligned: [(String, Double, Double)], _ text: String, offset: Double = 0,
    length: Double
  ) -> [Word] {
    WordTiming.words(
      WordTiming.locate(aligned, in: text, from: text.startIndex), text: text, offset: offset,
      length: length)
  }

  static func wordTimings(_ t: Runner) {
    t.test("words: shifted to file time, clamped into the window, never backwards") {
      let words = place(
        [("Hallo", 0.5, 1.0), (" ", 1.0, 1.1), ("Welt.", 0.8, 30.0)], "Hallo Welt.",
        offset: 100, length: 25)
      t.expect(words, [Word("Hallo", 100.5, 101.0), Word("Welt.", 100.8, 125.0)])
    }

    t.test("words: a partial alignment keeps the missing tail, timed after the last aligned word") {
      let words = place([("Eins", 1, 2), ("zwei", 2, 3)], "Eins zwei drei vier", length: 7)
      t.expect(words.map(\.text), ["Eins", "zwei", "drei", "vier"])
      t.expect(words[2].start, 3)
      t.expect(words[3].end, 7)
    }

    t.test("words: a word the aligner skipped keeps its place; folded punctuation stays") {
      let words = place(
        [("one", 0, 1), ("three—", 3, 4)], "one two three — four", offset: 10, length: 6)
      t.expect(words.map(\.text), ["one", "two", "three —", "four"])
      t.expect(words[1].start, 11)
      t.expect(words[1].end, 13)
      t.expect(words[3].start, 14)
      t.expect(words[3].end, 16)
    }

    t.test("words: an aligned word repeated by the aligner is not duplicated") {
      let words = place(
        [("one—", 0, 1), ("five", 1, 2), ("five", 2, 3), ("six", 3, 4)], "one — five six",
        length: 5)
      t.expect(words.map(\.text), ["one —", "five", "six"])
    }

    t.test("words: punctuation plus saturation recovers without duplicating words") {
      // First pass: "five" onward is stuck at 4.0 s (saturated); the retry gets exactly the
      // original text after the last reliable word and the audio after its end.
      let text = "one — two three four five six seven eight nine"
      var calls: [(String, Int)] = []
      let spans = WordTiming.alignWithRecovery(text: text, length: 16_000 * 12) { sub, from in
        calls.append((String(sub), from))
        if from == 0 {
          return [
            ("one—", 0, 0.5), ("two", 0.5, 1), ("three", 1, 1.5), ("four", 1.5, 2),
            ("five", 4, 4), ("six", 4, 4), ("seven", 4.02, 4.02), ("eight", 4.05, 4.05),
            ("nine", 4.05, 4.05),
          ]
        }
        return [("five", 0, 1), ("six", 1, 2), ("seven", 2, 3), ("eight", 3, 4), ("nine", 4, 5)]
      }
      let words = WordTiming.words(spans, text: text, offset: 0, length: 12)
      t.expect(
        words.map(\.text),
        ["one —", "two", "three", "four", "five", "six", "seven", "eight", "nine"])
      t.expect(calls.count, 2)
      t.expect(calls.last?.0.trimmingCharacters(in: .whitespaces), "five six seven eight nine")
      t.expect(calls.last?.1, 32_000, "retry starts at the end of 'four'")
      t.expect(words[4].start, 2, "retry times are shifted to the window")
    }

    t.test("words: unspaced text keeps a leading quote and an interior omission in place") {
      let words = place(
        [("今日", 0, 1), ("晴れ", 2, 3), ("です」", 3, 4)], "「今日は晴れです」", length: 5)
      t.expect(words.map(\.text).joined(), "「今日は晴れです」", "nothing lost or doubled")
      t.expect(words.map(\.text), ["「", "今日", "は", "晴れ", "です」"])
      t.expect(words[2].start, 1, "は sits between 今日 and 晴れ")
      t.expect(words[2].end, 2)
    }

    t.test("words: no alignment spreads the text over the window, losing no word") {
      let words = place([], "one two  three four", offset: 10, length: 4)
      t.expect(words.map(\.text), ["one", "two", "three", "four"])
      t.expect(words.first?.start, 10)
      t.expect(words.last?.end, 14)
    }

    t.test("silence: a window is skipped only if every 25 ms frame is silent") {
      var samples = [Float](repeating: 0, count: 25 * Audio.sampleRate)
      t.expect(Chunking.isSilent(samples, 0..<samples.count), "digital silence")
      // A half-second quiet reply (RMS 0.002) in 25 s of silence.
      for i in (10 * Audio.sampleRate)..<(10 * Audio.sampleRate + Audio.sampleRate / 2) {
        samples[i] = i % 2 == 0 ? 0.002 : -0.002
      }
      t.expect(
        Chunking.meanSquare(samples, 0..<samples.count) < Chunking.silenceMeanSquare,
        "whole-window average is below the threshold")
      t.expect(!Chunking.isSilent(samples, 0..<samples.count), "the quiet reply survives")
    }

    t.test("language: detection is constrained and unsure text gives nil") {
      t.expect(
        LanguageDetection.detect(
          "Das ist ein ganz normaler deutscher Satz über das Wetter und die Arbeit.",
          among: MLXEngine.qwen3Languages)?.code, "de")
      t.expect(LanguageDetection.detect("", among: MLXEngine.qwen3Languages) == nil, "empty")
      t.expect(
        LanguageDetection.detect("Bonjour, ça va très bien merci.", among: ["de", "en"]) == nil
          || LanguageDetection.detect("Bonjour, ça va très bien merci.", among: ["de", "en"])?
            .code != "fr",
        "never outside the candidates")
    }
  }

  /// A stand-in speech engine: one word per segment that runs past the segment's end.
  struct OverlongWord: TranscriptionEngine {
    func transcribe(_ audio: Audio, language: String?, progress: TMSM.Progress) async throws
      -> [Word]
    {
      [Word("w", 0.2, audio.duration + 3)]
    }
  }

  static func turnwise(_ t: Runner) {
    let sr = Audio.sampleRate
    let flat: (Range<Int>) -> Double = { _ in 1 }

    t.test("turns: no speaker segments give one speaker over the whole file, in ≤25 s pieces") {
      let pieces = TurnwiseDecoding.plan(
        segments: [], sampleCount: 60 * sr, maxSpeakers: 4, energy: flat)
      t.expect(pieces.first?.range.lowerBound, 0)
      t.expect(pieces.last?.range.upperBound, 60 * sr)
      t.expect(pieces.allSatisfy { $0.speaker == 0 && $0.range.count <= 25 * sr }, "≤25 s")
    }

    t.test("turns: overlap goes to the newcomer, gaps split in the middle, nothing dropped") {
      let segs = [
        SpeakerSegment(0, 0, 5), SpeakerSegment(1, 4, 8), SpeakerSegment(0, 10, 12),
        SpeakerSegment(0, 13, 14),
      ]
      let pieces = TurnwiseDecoding.plan(
        segments: segs, sampleCount: 15 * sr, maxSpeakers: 4, energy: flat)
      t.expect(pieces.map(\.speaker), [0, 1, 0])
      t.expect(pieces[0].range, 0..<(4 * sr), "speaker 1 takes over at 4 s")
      t.expect(pieces[1].range, (4 * sr)..<(9 * sr), "the 8–10 s gap splits at 9 s")
      t.expect(pieces[2].range, (9 * sr)..<(15 * sr), "same-speaker pause and tail stay in")
    }

    t.test("turns: words take their turn's speaker, clamped to the real turn length") {
      let audio = Audio(samples: [Float](repeating: 0, count: 10 * sr))
      let pieces = [
        TurnwiseDecoding.Piece(speaker: 3, range: 0..<(sr / 2)),
        TurnwiseDecoding.Piece(speaker: 1, range: (sr / 2)..<(10 * sr)),
      ]
      let done = DispatchSemaphore(value: 0)
      let result = Mutex<(words: [Word], speakers: [Int])?>(nil)
      Task {
        let r = try? await TurnwiseDecoding.decode(
          audio, pieces: pieces, engine: OverlongWord(), language: "de", progress: .silent)
        result.withLock { $0 = r }
        done.signal()
      }
      done.wait()
      let r = result.withLock { $0 }
      t.expect(r?.speakers ?? [], [3, 1])
      t.expect(r?.words.first, Word("w", 0.2, 0.5), "padded 0.5 s turn clamps to 0.5 s")
      t.expect(r?.words.last?.end, 10)
    }

    t.test("presets: every preset says how it combines speech and speakers") {
      t.expect(
        Catalogue.shared.presets.allSatisfy { [.windows, .turnwise].contains($0.strategy) }, "set")
    }
  }

  static func routing(_ t: Runner) {
    t.test("routing: entries in route order, detectors after, no repeats") {
      let r = LanguageRouting(
        routes: [.init("a", .turnwise, only: ["de"]), .init("b", .turnwise), .init("a", .windows)],
        detectors: ["b", "c"])
      t.expect(r.entries, ["a", "b", "c"])
    }

    t.test("routing: language names and detection from text") {
      t.expect(LanguageDetection.name("de"), "German")
      t.expect(LanguageDetection.name("en"), "English")
      t.expect(
        LanguageDetection.language(
          of: "Das ist ein ganz normaler deutscher Satz über das Wetter und die Arbeit."), "de")
      t.expect(
        LanguageDetection.language(
          of: "This is an ordinary English sentence about the weather and work."), "en")
    }

    t.test("routing: the detection sample takes up to three speech windows, skipping silence") {
      let sr = Audio.sampleRate
      var samples = [Float](repeating: 0, count: 120 * sr)
      for i in (30 * sr)..<(120 * sr) { samples[i] = i % 2 == 0 ? 0.1 : -0.1 }
      let sample = PresetRouting.speechSample(Audio(samples: samples))
      t.expect(
        sample.samples.filter { $0 == 0 }.count < 11 * sr, "the silent first window is left out")
      t.expect(sample.samples.count >= 50 * sr && sample.samples.count <= 75 * sr, "≈ a minute")
    }
  }
}
