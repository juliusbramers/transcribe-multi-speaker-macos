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
    if ProcessInfo.processInfo.environment["TMSM_SELFTEST_PREPARE"] == "1" { prepare(t) }
    if let clip = ProcessInfo.processInfo.environment["TMSM_SELFTEST_DETERMINISM"] {
      determinism(t, clip: clip)
    }
    if let probe = ProcessInfo.processInfo.environment["TMSM_SELFTEST_PROBE"] {
      self.probe(t, probe)
    }
  }

  /// Opt-in measurement: `TMSM_SELFTEST_PROBE=<entry id>:<file>:<output folder>` runs a full
  /// pipeline with that transcription entry and Nemotron-3 offline, for entries no preset uses.
  static func probe(_ t: Runner, _ spec: String) {
    let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return t.test("probe") { t.expect(false, "bad probe spec") } }
    let home = TMSMHome.resolve()
    let preset = Preset(
      name: "probe", transcription: parts[0], speakers: "nemotron3-offline", summary: "",
      ramGB: nil)
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
          for id in [p.transcription, p.speakers] {
            try await Catalogue.shared.entry(id).prepare(home, .silent)
          }
        }
      } catch { failure.withLock { $0 = "\(error)" } }
      done.signal()
    }
    done.wait()
    t.test("prepare: every preset's models download without running") {
      t.expect(failure.withLock { $0 } == nil, "prepare failed: \(failure.withLock { $0 } ?? "")")
      for spec in MLXEngine.transcribers {
        t.expect(MLXEngine.isDownloaded(spec.model, home), "\(spec.id) on disk")
      }
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
          t.expect(id != Presets.extremeRouter, "a route never points at the router")
        }
      }
    }

    t.test("presets: accurate is Qwen3-ASR 1.7B 8-bit with Nemotron-3 offline") {
      let p = try Catalogue.shared.preset(named: "accurate")
      t.expect(p.transcription, "qwen3-asr-1.7b-8bit")
      t.expect(p.speakers, "nemotron3-offline")
      t.expect(
        Catalogue.shared.presets.allSatisfy { $0.ramGB.map { $0.lowerBound > 0 } ?? true },
        "RAM > 0")
    }

    t.test("presets: extreme routes, and covers German and English") {
      let p = try Catalogue.shared.preset(named: "extreme")
      t.expect(p.transcription, Presets.extremeRouter)
      t.expect(p.routing != nil, "extreme has a routing table")
      let router = try Catalogue.shared.entry(Presets.extremeRouter)
      t.expect(router.languages.contains("de") && router.languages.contains("en"), "de and en")
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

  static func wordTimings(_ t: Runner) {
    t.test("words: shifted to file time, clamped into the window, never backwards") {
      let words = WordTiming.place(
        [("Hallo", 0.5, 1.0), (" ", 1.0, 1.1), ("Welt.", 0.8, 30.0)], text: "Hallo Welt.",
        offset: 100, length: 25)
      t.expect(words, [Word("Hallo", 100.5, 101.0), Word("Welt.", 100.8, 125.0)])
    }

    t.test("words: no alignment spreads the text over the window, losing no word") {
      let words = WordTiming.place([], text: "one two  three four", offset: 10, length: 4)
      t.expect(words.map(\.text), ["one", "two", "three", "four"])
      t.expect(words.first?.start, 10)
      t.expect(words.last?.end, 14)
    }
  }

  static func routing(_ t: Runner) {
    t.test("routing: listed languages go to their entry, the rest to the fallback") {
      let r = LanguageRouting(byLanguage: ["de": "parakeet-ultra", "en": "a"], fallback: "a")
      t.expect(r.entry(for: "de"), "parakeet-ultra")
      t.expect(r.entry(for: "fr"), "a")
      t.expect(r.entries, ["a", "parakeet-ultra"], "fallback first, no duplicates")
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

    t.test("routing: the detection prefix is the first minute, cut near a quiet point") {
      let short = Audio(samples: [Float](repeating: 0.1, count: 30 * Audio.sampleRate))
      t.expect(RoutedTranscriber.detectionPrefix(short).samples.count, short.samples.count)
      let long = Audio(samples: [Float](repeating: 0.1, count: 120 * Audio.sampleRate))
      let n = RoutedTranscriber.detectionPrefix(long).samples.count
      t.expect(n > 55 * Audio.sampleRate && n <= 60 * Audio.sampleRate, "55–60 s, got \(n)")
    }
  }
}
