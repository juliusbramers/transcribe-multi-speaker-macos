import Foundation
import Synchronization
import TMSM

enum CoreCases {
  static func run(_ t: Runner) {
    assignment(t)
    rendering(t)
    flags(t)
    naming(t)
    progress(t)
    homeAndCatalogue(t)
  }

  // MARK: Assignment

  static func assignment(_ t: Runner) {
    let w = [Word("a", 0.0, 0.4), Word("b", 0.5, 0.9), Word("c", 1.0, 1.4), Word("d", 1.5, 1.9)]

    t.test("assign: most overlap wins") {
      // b overlaps speaker 5 by 0.3 s and speaker 2 by 0.1 s.
      let segs = [SpeakerSegment(5, 0.0, 0.8), SpeakerSegment(2, 0.8, 2.0)]
      t.expect(SpeakerAssignment.assign(words: w, segments: segs, maxSpeakers: 4), [1, 1, 2, 2])
    }

    t.test("assign: numbered by first appearance, not engine index") {
      let segs = [SpeakerSegment(7, 0.0, 0.95), SpeakerSegment(0, 0.95, 2.0)]
      t.expect(SpeakerAssignment.assign(words: w, segments: segs, maxSpeakers: 4), [1, 1, 2, 2])
    }

    t.test("assign: exact tie goes to the previous word's speaker") {
      // c (1.0–1.4) overlaps 3 and 1 by 0.2 s each; the previous word was speaker 3.
      let segs = [SpeakerSegment(3, 0.0, 1.2), SpeakerSegment(1, 1.2, 2.0)]
      t.expect(SpeakerAssignment.assign(words: w, segments: segs, maxSpeakers: 4), [1, 1, 1, 2])
    }

    t.test("assign: tie without history goes to the lowest index, whatever the order") {
      let one = [Word("x", 0.0, 0.4)]
      let a = [SpeakerSegment(4, 0.0, 0.2), SpeakerSegment(2, 0.2, 0.4)]
      let b = Array(a.reversed())
      let ra = SpeakerAssignment.assign(words: one, segments: a, maxSpeakers: 4)
      let rb = SpeakerAssignment.assign(words: one, segments: b, maxSpeakers: 4)
      t.expect(ra, rb, "order independent")
      // Both renumber to 1; check the engine choice through a second word.
      let two = [Word("x", 0.0, 0.4), Word("y", 1.0, 1.2)]
      let segs = a + [SpeakerSegment(2, 1.0, 1.2)]
      t.expect(SpeakerAssignment.assign(words: two, segments: segs, maxSpeakers: 4), [1, 1])
    }

    t.test("assign: a gap within maxGap takes the nearest segment") {
      let words = [Word("a", 0.0, 0.4), Word("b", 2.0, 2.2)]
      let segs = [SpeakerSegment(0, 0.0, 0.4), SpeakerSegment(1, 2.5, 3.0)]
      // b is 0.3 s from speaker 1 and 1.6 s from speaker 0.
      t.expect(SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4), [1, 2])
    }

    t.test("assign: beyond maxGap the previous speaker continues") {
      let words = [Word("a", 0.0, 0.4), Word("b", 5.0, 5.2)]
      let segs = [SpeakerSegment(0, 0.0, 0.4), SpeakerSegment(1, 7.0, 8.0)]
      t.expect(SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4), [1, 1])
    }

    t.test("assign: leading unmatched words take the first assigned speaker") {
      let words = [Word("a", 0.0, 0.2), Word("b", 10.0, 10.2), Word("c", 20.0, 20.2)]
      let segs = [SpeakerSegment(3, 10.0, 10.2), SpeakerSegment(1, 20.0, 20.2)]
      t.expect(SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4), [1, 1, 2])
    }

    t.test("assign: no segments → one speaker") {
      t.expect(SpeakerAssignment.assign(words: w, segments: [], maxSpeakers: 4), [1, 1, 1, 1])
      t.expect(SpeakerAssignment.assign(words: [], segments: [], maxSpeakers: 4), [])
    }

    t.test("assign: the cap drops the speakers with the least speech") {
      let words = (0..<6).map { Word("w\($0)", Double($0), Double($0) + 0.5) }
      let segs = [
        SpeakerSegment(0, 0, 2.6),  // 2.6 s
        SpeakerSegment(1, 2.6, 3.6),  // 1.0 s
        SpeakerSegment(2, 3.6, 3.65),  // 0.05 s → dropped
        SpeakerSegment(2, 3.9, 4.0),
        SpeakerSegment(1, 4.0, 6.0),
      ]
      let result = SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 2)
      t.expect(Set(result).count <= 2, "at most two speakers")
      t.expect(result, [1, 1, 1, 2, 2, 2])
    }

    t.test("assign: zero-length words still land in their segment") {
      let words = [Word("a", 1.0, 1.0)]
      let segs = [SpeakerSegment(0, 0.0, 0.99), SpeakerSegment(1, 0.99, 2.0)]
      let r = SpeakerAssignment.assign(
        words: words + [Word("b", 0.1, 0.2)], segments: segs, maxSpeakers: 4)
      t.expect(r, [1, 2])
    }

    t.test("assign: frame activity decides between overlapping speakers") {
      // Both segments cover the word fully (binary tie); speaker 1 is louder in the frames.
      let words = [Word("a", 0.0, 0.2), Word("b", 1.0, 1.2)]
      let segs = [SpeakerSegment(0, 0.0, 2.0), SpeakerSegment(1, 0.9, 2.0)]
      var values = [Float](repeating: 0, count: 200 * 2)
      for f in 0..<200 { values[f * 2] = 0.6 }
      for f in 90..<200 { values[f * 2 + 1] = 0.9 }
      let act = SpeakerActivity(frameSeconds: 0.01, speakers: 2, values: values)
      let without = SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4)
      t.expect(without, [1, 1], "binary tie keeps the previous speaker")
      let with = SpeakerAssignment.assign(
        words: words, segments: segs, activity: act, maxSpeakers: 4)
      t.expect(with, [1, 2], "activity picks the louder speaker")
      t.expect(abs(act.mass(1, 1.0, 1.2) - 0.18) < 1e-6, "mass = sum × frame length")
      t.expect(act.mass(5, 0, 1), 0, "unknown speaker has no mass")
    }

    t.test("assign: a lone short word inside another speaker's flow joins it") {
      let words = [
        Word("nur", 0.0, 0.3), Word("dann", 0.35, 0.5), Word("sonst", 0.55, 0.9),
      ]
      let segs = [
        SpeakerSegment(0, 0.0, 0.32), SpeakerSegment(1, 0.33, 0.52),
        SpeakerSegment(0, 0.53, 1.0),
      ]
      t.expect(SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4), [1, 1, 1])
    }

    t.test("assign: a real backchannel keeps its speaker") {
      // "Genau." is long enough (0.5 s) to be its own turn.
      let words = [Word("so", 0.0, 0.3), Word("Genau.", 0.4, 0.9), Word("und", 1.0, 1.2)]
      let segs = [
        SpeakerSegment(0, 0.0, 0.35), SpeakerSegment(1, 0.38, 0.95),
        SpeakerSegment(0, 0.97, 1.3),
      ]
      t.expect(SpeakerAssignment.assign(words: words, segments: segs, maxSpeakers: 4), [1, 2, 1])
      // Same short word after a long pause also stays.
      let paused = [Word("so", 0.0, 0.3), Word("ja", 1.0, 1.2), Word("und", 1.3, 1.5)]
      let segs2 = [
        SpeakerSegment(0, 0.0, 0.3), SpeakerSegment(1, 1.0, 1.2), SpeakerSegment(0, 1.3, 1.5),
      ]
      t.expect(
        SpeakerAssignment.assign(words: paused, segments: segs2, maxSpeakers: 4), [1, 2, 1])
    }

    t.test("assign: --speakers 1 merges everything") {
      let segs = [SpeakerSegment(0, 0.0, 0.9), SpeakerSegment(1, 0.9, 2.0)]
      t.expect(SpeakerAssignment.assign(words: w, segments: segs, maxSpeakers: 1), [1, 1, 1, 1])
    }
  }

  // MARK: Rendering

  static func rendering(_ t: Runner) {
    t.test("render: heading, then one paragraph per turn") {
      let words = [Word("Hallo", 0, 1), Word("zusammen.", 1, 2), Word("Hi!", 2, 3)]
      let md = Transcript(title: "memo.opus", words: words, speakers: [1, 1, 2]).markdown
      t.expect(md, "# memo.opus\n\nSpeaker 1: Hallo zusammen.\n\nSpeaker 2: Hi!\n")
    }

    t.test("render: a speaker returning starts a new paragraph") {
      let words = [Word("a", 0, 1), Word("b", 1, 2), Word("c", 2, 3)]
      let tr = Transcript(title: "x", words: words, speakers: [1, 2, 1])
      t.expect(tr.turns.map(\.speaker), [1, 2, 1])
      t.expect(tr.speakerCount, 2)
    }

    t.test("render: no timestamps, no empty words, no speech note") {
      let tr = Transcript(title: "x", words: [Word(" ", 0, 1)], speakers: [1])
      t.expect(tr.markdown, "# x\n\n_No speech found._\n")
      let md = Transcript(title: "x", words: [Word("a", 61, 62)], speakers: [1]).markdown
      t.expect(!md.contains(":01") && !md.contains("61"), "no timestamps")
    }

    t.test("render: a newline in the file name stays on the heading line") {
      let md = Transcript(title: "a\nb", turns: []).markdown
      t.expect(md.hasPrefix("# a b\n"), "heading on one line")
    }
  }

  // MARK: Flags

  static func flags(_ t: Runner) {
    t.test("flags: defaults") {
      let o = try RunOptions.parse(["memo.opus"])
      t.expect(o.file, "memo.opus")
      t.expect(o.speakers, .auto)
      t.expect(o.speakers.limit, 4)
      t.expect(o.languageCode, nil)
      t.expect(o.output, nil)
      t.expect(o.preset, nil)
      t.expect(o.json, false)
      t.expect(o.quiet, false)
    }

    t.test("flags: every flag") {
      let o = try RunOptions.parse([
        "a.m4a", "--speakers", "3", "--language", "de-DE", "--output", "out/", "--preset",
        "fast", "--json", "--quiet",
      ])
      t.expect(o.speakers, .exactly(3))
      t.expect(o.speakers.limit, 3)
      t.expect(o.languageCode, "de")
      t.expect(o.output, "out/")
      t.expect(o.preset, "fast")
      t.expect(o.json && o.quiet, "json and quiet")
      let short = try RunOptions.parse(["a.m4a", "-o", "x.md", "-q"])
      t.expect(short.output, "x.md")
      t.expect(short.quiet, true)
    }

    t.test("flags: --speakers accepts 1-4 and auto only") {
      for good in ["1", "2", "3", "4", "auto", "AUTO"] {
        t.expect((try? RunOptions.parse(["a", "--speakers", good])) != nil, "accepts \(good)")
      }
      for bad in ["0", "5", "-1", "two", ""] {
        t.expect((try? RunOptions.parse(["a", "--speakers", bad])) == nil, "rejects \(bad)")
      }
    }

    t.test("flags: a file is required") {
      t.expect((try? RunOptions.parse([])) == nil, "no file rejected")
    }

    t.test("flags: preset and language are checked against the catalogue") {
      let cat = Catalogue.shared
      t.expect((try? cat.preset(named: "fast"))?.transcription, "parakeet-v3")
      t.expect((try? cat.preset(named: "Default"))?.transcription, "parakeet-ultra")
      t.expect((try? cat.preset(named: "nope")) == nil, "unknown preset rejected")
      let parakeet = try cat.entry("parakeet-ultra")
      t.expect(parakeet.languages.count, 25)
      t.expect(parakeet.languages.contains("de") && !parakeet.languages.contains("ja"), "langs")
    }
  }

  // MARK: Naming

  static func naming(_ t: Runner) {
    let desktop = URL(fileURLWithPath: "/Users/u/Desktop")
    let cwd = URL(fileURLWithPath: "/work", isDirectory: true)
    let input = URL(fileURLWithPath: "/in/memo.opus")
    func target(_ output: String?, dirs: Set<String> = []) -> String {
      OutputFile.target(
        input: input, output: output, desktop: desktop, cwd: cwd,
        isDirectory: { dirs.contains($0.path) }
      ).path
    }

    t.test("naming: Desktop by default, input name with .md") {
      t.expect(target(nil), "/Users/u/Desktop/memo.md")
      t.expect(
        OutputFile.target(
          input: URL(fileURLWithPath: "/in/WhatsApp Audio 2026.ogg"), output: nil,
          desktop: desktop, cwd: cwd
        ).lastPathComponent, "WhatsApp Audio 2026.md")
    }

    t.test("naming: --output folder, file and relative paths") {
      t.expect(target("/tmp/out/"), "/tmp/out/memo.md")
      t.expect(target("/tmp/existing", dirs: ["/tmp/existing"]), "/tmp/existing/memo.md")
      t.expect(target("/tmp/notes.md"), "/tmp/notes.md")
      t.expect(target("/tmp/notes"), "/tmp/notes.md")
      t.expect(target("sub/x.md"), "/work/sub/x.md")
    }

    t.test("naming: copies are numbered like Finder's") {
      let base = URL(fileURLWithPath: "/d/memo.md")
      t.expect(OutputFile.candidate(base, 1).path, "/d/memo.md")
      t.expect(OutputFile.candidate(base, 2).path, "/d/memo 2.md")
      t.expect(OutputFile.candidate(URL(fileURLWithPath: "/d/x"), 3).path, "/d/x 3")
    }

    t.test("naming: never overwrites") {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tmsm-selftest-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let target = dir.appendingPathComponent("memo.md")
      let first = try OutputFile.write("one", to: target)
      let second = try OutputFile.write("two", to: target)
      t.expect(first.lastPathComponent, "memo.md")
      t.expect(second.lastPathComponent, "memo 2.md")
      t.expect(try String(contentsOf: first, encoding: .utf8), "one")
      t.expect(try String(contentsOf: second, encoding: .utf8), "two")
      t.expect(
        (try? OutputFile.write("three", to: target, attempts: 2)) == nil, "gives up, no overwrite")
    }
  }

  // MARK: Progress

  final class Lines: Sendable {
    let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { s in self.lines.withLock { $0.append(s) } } }
  }

  static func progress(_ t: Runner) {
    t.test("progress: mode") {
      t.expect(Progress.mode(quiet: true, isTerminal: true), .quiet)
      t.expect(Progress.mode(quiet: false, isTerminal: true), .bar)
      t.expect(Progress.mode(quiet: false, isTerminal: false), .lines)
    }

    t.test("progress: bar line has stage, percent and time left") {
      let line = Progress.barLine(stage: "Transcribing", fraction: 0.5, elapsed: 30, width: 10)
      t.expect(line, "Transcribing  █████░░░░░  50%  0:30 left")
      let early = Progress.barLine(stage: "S", fraction: 0.01, elapsed: 5, width: 4)
      t.expect(early, "S  ░░░░   1%", "no estimate this early")
      t.expect(Progress.barLine(stage: "S", fraction: 2, elapsed: 5, width: 2), "S  ██ 100%")
    }

    t.test("progress: activity line has a spinner and elapsed time") {
      t.expect(
        Progress.activityLine(stage: "Compiling", frame: 0, elapsed: 75), "Compiling  ⠋ 1:15")
      t.expect(Progress.clockTime(3725), "1:02:05")
      t.expect(Progress.clockTime(-3), "0:00")
    }

    t.test("progress: without a terminal, one plain line per stage") {
      let out = Lines()
      let p = Progress(mode: .lines, sink: out.sink, clock: { 0 })
      p.activity("Decoding audio")
      p.stage("Transcribing")
      p.update(0.3)
      p.update(0.6)
      p.stage("Transcribing")
      p.activity("Labelling speakers")
      p.activity("Transcribing")
      p.finish()
      t.expect(
        out.all, ["tmsm: Decoding audio\n", "tmsm: Transcribing\n", "tmsm: Labelling speakers\n"])
    }

    t.test("progress: quiet prints nothing") {
      let out = Lines()
      let p = Progress(mode: .quiet, sink: out.sink)
      p.activity("a")
      p.stage("b")
      p.update(0.5)
      p.finish()
      t.expect(out.all, [])
    }

    t.test("progress: the bar redraws in place and clears at the end") {
      let out = Lines()
      let p = Progress(mode: .bar, sink: out.sink, clock: { 100 })
      p.stage("Transcribing")
      p.update(1)
      p.finish()
      let all = out.all
      t.expect(all.allSatisfy { $0.hasPrefix("\r\u{1B}[2K") }, "every draw starts with a clear")
      t.expect(all.contains { $0.contains("100%") }, "reaches 100%")
      t.expect(all.last, "\r\u{1B}[2K", "ends cleared")
      t.expect(!all.joined().contains("\n"), "never scrolls")
    }
  }

  // MARK: Home and catalogue

  static func homeAndCatalogue(_ t: Runner) {
    t.test("home: TMSM_HOME wins, else Application Support under $HOME") {
      let a = TMSMHome.resolve(environment: ["TMSM_HOME": "/x/home", "HOME": "/Users/u"])
      t.expect(a.root.path, "/x/home")
      let b = TMSMHome.resolve(environment: ["HOME": "/Users/u"])
      t.expect(b.root.path, "/Users/u/Library/Application Support/tmsm")
      t.expect(a.models(engine: "fluidaudio").path, "/x/home/models/fluidaudio")
      t.expect(a.configFile.path, "/x/home/config.json")
    }

    t.test("home: every engine path stays inside the root") {
      let home = TMSMHome(root: URL(fileURLWithPath: "/r"))
      for entry in Catalogue.shared.entries {
        for url in entry.storage(home) {
          t.expect(url.path.hasPrefix("/r/models/\(entry.engine)/"), "\(entry.id) under its folder")
        }
      }
      for url in [home.temporary, home.urlCache, home.huggingFace] {
        t.expect(url.path.hasPrefix("/r/cache/"), "\(url.path) under cache/")
      }
    }

    t.test("home: system leftovers are exactly the two tmsm-named folders") {
      let paths = SystemPaths.leftovers(environment: ["HOME": "/Users/u"]).map(\.path)
      t.expect(paths, ["/Users/u/Library/Caches/tmsm", "/Users/u/Library/HTTPStorages/tmsm"])
    }

    t.test("catalogue: fast and default are token-free FluidAudio presets") {
      let cat = Catalogue.shared
      for name in ["fast", "default"] {
        let p = try cat.preset(named: name)
        let asr = try cat.entry(p.transcription)
        let spk = try cat.entry(p.speakers)
        t.expect(asr.kind, .transcription, name)
        t.expect(spk.kind, .speakers, name)
        t.expect(!asr.gated && !spk.gated, "\(name) needs no token")
      }
      t.expect(try cat.preset(named: "fast").speakers, "nemotron3-c128-split-w8a8")
      t.expect(try cat.preset(named: "default").speakers, "nemotron3-offline")
      t.expect(Set(cat.entries.map(\.id)).count, cat.entries.count, "unique ids")
    }

    t.test("config: missing file means no choice; round trip") {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tmsm-selftest-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("config.json")
      t.expect(try Config.load(from: file), Config())
      try Config(preset: "fast").save(to: file)
      t.expect(try Config.load(from: file).preset, "fast")
    }
  }
}
