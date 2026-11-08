import Foundation
import TMSM

/// Setup, install, update, uninstall and the docs. Nothing here downloads a model or touches
/// the real Keychain, home or PATH: every case works in its own temp folder.
enum SetupCases {
  static func run(_ t: Runner) {
    config(t)
    choosing(t)
    token(t)
    unused(t)
    pathLine(t)
    program(t)
    ownership(t)
    uninstall(t)
    recovery(t)
    update(t)
    pipes(t)
    docs(t)
  }

  // MARK: Fixtures

  struct Silent: TranscriptionEngine, SpeakerEngine {
    func transcribe(_ audio: Audio, language: String?, progress: TMSM.Progress) async throws
      -> [Word]
    {
      []
    }
    func label(_ audio: Audio, maxSpeakers: Int, progress: TMSM.Progress) async throws
      -> SpeakerTrack
    {
      SpeakerTrack(segments: [])
    }
  }

  static func entry(
    _ id: String, _ kind: CatalogueEntry.Kind, gated: Bool = false, mb: Int = 100
  ) -> CatalogueEntry {
    CatalogueEntry(
      id: id, name: id.uppercased(), engine: "test", languages: kind == .speakers ? [] : ["de"],
      downloadMB: mb, license: "MIT", gated: gated,
      factory: kind == .transcription
        ? .transcription { _ in Silent() } : .speakers { _ in Silent() },
      storage: { home in [home.models(engine: "test").appendingPathComponent(id)] })
  }

  /// asr-a/asr-b/asr-gated, spk-a/spk-b; presets fast (a+a) and default (b+b).
  static let catalogue = Catalogue(
    [
      EngineRegistration(
        engine: "test",
        entries: [
          entry("asr-a", .transcription, mb: 400), entry("asr-b", .transcription, mb: 700),
          entry("asr-gated", .transcription, gated: true),
          entry("spk-a", .speakers, mb: 90), entry("spk-b", .speakers, mb: 190),
        ])
    ], presets: presets)

  /// fast: measured RAM; default: none yet; routed: two speech models and a detector.
  static let presets = [
    Preset(
      name: "fast", transcription: "asr-a", speakers: "spk-a", summary: "A", ramGB: 0.4...0.4),
    Preset(name: "default", transcription: "asr-b", speakers: "spk-b", summary: "B", ramGB: nil),
    Preset(
      name: "routed", speakers: "spk-a", summary: "R", ramGB: 0.4...6.2,
      routing: LanguageRouting(
        routes: [.init("asr-a", .turnwise, only: ["de"]), .init("asr-b", .windows)],
        detectors: ["asr-b"])),
  ]

  /// Runs async code from the synchronous runner.
  static func blocking(_ body: @escaping @Sendable () async throws -> Void) throws {
    final class Outcome: @unchecked Sendable { var error: Error? }
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    Task {
      do { try await body() } catch { outcome.error = error }
      done.signal()
    }
    done.wait()
    if let error = outcome.error { throw error }
  }

  final class Scripted: Console, @unchecked Sendable {
    var answers: [String]
    var hidden: [String]
    var said: [String] = []
    let isInteractive: Bool
    init(_ answers: [String], hidden: [String] = [], interactive: Bool = true) {
      self.answers = answers
      self.hidden = hidden
      isInteractive = interactive
    }
    func say(_ text: String) { said.append(text) }
    func ask(_ prompt: String) -> String? { answers.isEmpty ? nil : answers.removeFirst() }
    func askHidden(_ prompt: String) -> String? { hidden.isEmpty ? nil : hidden.removeFirst() }
  }

  static func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmsm-selftest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// An installed program folder as `tmsm install` leaves it: `tmsm` plus its manifest.
  static func fakeInstall(_ installer: Installer) throws {
    try write("tmsm", installer.executable)
    try write(
      "# tmsm program folder\nitem tmsm\n",
      installer.programFolder.appendingPathComponent(Installer.manifestName))
  }

  /// A 16 kHz mono 16-bit WAV of a quiet tone.
  static func wav(seconds: Int) -> Data {
    let count = seconds * Audio.sampleRate
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(UInt32(Audio.sampleRate))
    u32(UInt32(Audio.sampleRate * 2))
    u16(2)
    u16(16)
    data.append(contentsOf: Array("data".utf8))
    u32(UInt32(count * 2))
    for i in 0..<count {
      let v = Int16(3000 * sin(Double(i) * 2 * .pi * 220 / Double(Audio.sampleRate)))
      withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

  static func expectError<E: Error & Equatable>(
    _ t: Runner, _ expected: E, line: Int = #line, _ body: () throws -> Void
  ) {
    do {
      try body()
      t.fail("expected \(expected), got no error (line \(line))")
    } catch let error as E {
      t.expect(error, expected, line: line)
    } catch {
      t.fail("expected \(expected), got \(error) (line \(line))")
    }
  }

  // MARK: Config

  static func config(_ t: Runner) {
    t.test("config: --preset, then the configured preset, then default") {
      t.expect(try Config().resolvePreset(nil, catalogue: catalogue).name, "default")
      t.expect(try Config(preset: "fast").resolvePreset(nil, catalogue: catalogue).name, "fast")
      t.expect(
        try Config(preset: "fast").resolvePreset("DEFAULT", catalogue: catalogue).name, "default")
    }

    t.test("config: individual is the two configured models") {
      let config = Config(preset: "individual", transcription: "asr-a", speakers: "spk-b")
      let preset = try config.resolvePreset(nil, catalogue: catalogue)
      t.expect(preset.transcription, "asr-a")
      t.expect(preset.speakers, "spk-b")
      expectError(t, SetupError.noIndividualModels) {
        _ = try Config(preset: "individual").resolvePreset(nil, catalogue: catalogue)
      }
      expectError(t, SetupError.wrongKind("spk-a", .transcription)) {
        _ = try Config(preset: "individual", transcription: "spk-a", speakers: "spk-b")
          .resolvePreset(nil, catalogue: catalogue)
      }
      expectError(t, TMSMError.unknownModel("nope")) {
        _ = try Config(preset: "individual", transcription: "nope", speakers: "spk-b")
          .resolvePreset(nil, catalogue: catalogue)
      }
    }

    t.test("config: saved and loaded unchanged; old files without models still load") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("config.json")
      let config = Config(preset: "individual", transcription: "asr-a", speakers: "spk-a")
      try config.save(to: file)
      t.expect(try Config.load(from: file), config)
      try write(#"{"preset":"fast"}"#, file)
      t.expect(try Config.load(from: file), Config(preset: "fast"))
    }
  }

  // MARK: Choosing

  static func choosing(_ t: Runner) {
    let home = TMSMHome(root: URL(fileURLWithPath: "/nonexistent/tmsm-home"))
    let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])

    t.test("setup flags: a preset, or models that imply individual") {
      t.expect(
        try setup.config(preset: "FAST", transcription: nil, speakers: nil, current: Config()),
        Config(preset: "fast"))
      t.expect(
        try setup.config(
          preset: nil, transcription: "asr-a", speakers: nil, current: Config(preset: "default")),
        Config(preset: "individual", transcription: "asr-a", speakers: "spk-b"),
        "the missing half comes from the current preset")
      expectError(t, TMSMError.unknownPreset("best")) {
        _ = try setup.config(preset: "best", transcription: nil, speakers: nil, current: Config())
      }
      expectError(t, SetupError.wrongKind("asr-a", .speakers)) {
        _ = try setup.config(
          preset: nil, transcription: nil, speakers: "asr-a", current: Config())
      }
      expectError(t, SetupError.noIndividualModels) {
        _ = try setup.config(
          preset: "individual", transcription: nil, speakers: nil, current: Config())
      }
    }

    t.test("wizard: Enter keeps the current preset; a number picks one") {
      t.expect(try setup.ask(Scripted([""]), current: Config()), Config(preset: "default"))
      t.expect(
        try setup.ask(Scripted([""]), current: Config(preset: "fast")), Config(preset: "fast"))
      t.expect(try setup.ask(Scripted(["x", "9", "1"]), current: Config()), Config(preset: "fast"))
      expectError(t, SetupError.cancelled) { _ = try setup.ask(Scripted([]), current: Config()) }
    }

    t.test("wizard: individual asks for one model of each kind") {
      // choices: fast, default, routed, individual; transcription: asr-a, asr-b, asr-gated.
      let console = Scripted(["4", "1", ""])
      t.expect(
        try setup.ask(console, current: Config()),
        Config(preset: "individual", transcription: "asr-a", speakers: "spk-b"),
        "Enter keeps the current preset's speaker model")
      t.expect(console.said.contains { $0.contains("gated") }, "gated models are marked")
    }

    t.test("wizard and --list show catalogue figures, not hand-written ones") {
      let console = Scripted(["1"])
      _ = try setup.ask(console, current: Config())
      t.expect(
        console.said.contains { $0.contains("fast: A; peak RAM 0.4 GB, 490 MB download") },
        "fast line: \(console.said)")
      t.expect(
        console.said.contains { $0.contains("default: B, 890 MB download") }, "no RAM yet")
      let list = setup.listing(current: Config(preset: "fast"))
      t.expect(list.contains("* fast        A; peak RAM 0.4 GB\n"), "fast marked:\n\(list)")
      t.expect(list.contains("490 MB download: asr-a, spk-a"), "fast models")
      t.expect(list.contains("  routed      R; peak RAM 0.4–6.2 GB"), "range")
      t.expect(
        list.contains("1.2 GB download: asr-a, asr-b, spk-a"), "every routed model counted once")
      t.expect(list.contains("asr-gated  ASR-GATED, 100 MB, 1 languages, MIT, gated"), "gated")
      t.expect(
        setup.listing(current: Config()).contains("* default"), "no config: default is in use")
    }

    t.test("setup: fast and default stay small; fallbacks come later, and stay kept") {
      let real = ModelSetup(home: home, catalogue: .shared, environment: [:])
      func ids(_ name: String) throws -> [String] {
        real.setupIDs(try Catalogue.shared.preset(named: name))
      }
      t.expect(try ids("fast"), ["parakeet-ultra", "nemotron3-offline"])
      t.expect(try ids("default"), ["parakeet-ultra", "nemotron3-offline"])
      t.expect(try ids("accurate"), ["parakeet-ultra", "nemotron3-offline"])
      t.expect(
        try ids("extreme"),
        ["moss-transcribe-diarize-0.9b-8bit", "parakeet-ultra", "nemotron3-offline"])
      let fast = try Catalogue.shared.preset(named: "fast")
      t.expect(real.laterIDs(fast), ["qwen3-asr-1.7b-8bit"])
      t.expect(real.downloadMB(fast) < 1_000, "fast setup under 1 GB: \(real.downloadMB(fast)) MB")
      t.expect(
        ModelSetup.modelIDs(fast).contains("qwen3-asr-1.7b-8bit"),
        "a fetched fallback counts as the preset's, so it is never offered for deletion")
      let list = real.listing(current: Config())
      t.expect(list.contains("other languages may add"), "--list names the later download")
    }

    t.test("setup: a routed preset prepares every entry it may run, once each") {
      final class Log: @unchecked Sendable { var ids: [String] = [] }
      let log = Log()
      func logged(_ id: String, _ kind: CatalogueEntry.Kind) -> CatalogueEntry {
        var e = entry(id, kind)
        e.prepare = { _, _ in log.ids.append(id) }
        return e
      }
      let cat = Catalogue(
        [
          EngineRegistration(
            engine: "test",
            entries: [
              logged("asr-a", .transcription), logged("asr-b", .transcription),
              logged("spk-a", .speakers),
            ])
        ], presets: presets)
      let routed = try cat.preset(named: "routed")
      let s = ModelSetup(home: home, catalogue: cat, environment: [:])
      try blocking { try await s.prepare(routed, progress: .silent) }
      t.expect(log.ids, ["asr-a", "asr-b", "spk-a"])
    }
  }

  // MARK: Token

  static func token(_ t: Runner) {
    let home = TMSMHome(root: URL(fileURLWithPath: "/nonexistent/tmsm-home"))
    let gated = Preset(
      name: "individual", transcription: "asr-gated", speakers: "spk-a", summary: "", ramGB: nil)

    t.test("token: HF_TOKEN means nothing is asked") {
      let setup = ModelSetup(
        home: home, catalogue: catalogue, environment: ["HF_TOKEN": "hf_abcdefgh123"])
      let console = Scripted([])
      try setup.ensureToken(for: gated, console: console)
      t.expect(console.said.isEmpty, "no question")
    }

    t.test("token: no terminal means no Keychain access; HF_TOKEN or a clear error") {
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      expectError(t, SetupError.tokenMissing("ASR-GATED")) {
        try setup.ensureToken(for: gated, console: Scripted([], interactive: false))
      }
      expectError(t, SetupError.tokenMissing("M")) {
        try Credentials.exportToken(for: "M", environment: [:], attended: false)
      }
      t.expect(try Credentials.token(environment: [:], attended: false), nil)
      t.expect(
        try Credentials.token(environment: ["HF_TOKEN": "hf_x"], attended: false), "hf_x")
      try setup.ensureToken(
        for: catalogue.preset(named: "fast"), console: Scripted([], interactive: false))
    }

    t.test("token: an empty answer at the hidden prompt cancels") {
      // Reads the real Keychain (read-only); holds only if no token is stored there.
      guard (try? Credentials.stored()) == nil else { return }
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      expectError(t, SetupError.cancelled) {
        try setup.ensureToken(for: gated, console: Scripted([], hidden: ["", "x"]))
      }
    }

    t.test("token: shape check") {
      t.expect(Credentials.looksValid("hf_AbCdEf123456"), true)
      t.expect(Credentials.looksValid("hf_short"), false)
      t.expect(Credentials.looksValid("ghp_abcdefghijkl"), false)
      t.expect(Credentials.looksValid("hf_abc def12345"), false)
    }

    // Writes to the login Keychain, so it runs only on request.
    if ProcessInfo.processInfo.environment["TMSM_KEYCHAIN_TEST"] == "1" {
      t.test("token: Keychain store, read, replace, remove (TMSM_KEYCHAIN_TEST=1)") {
        try Credentials.store("hf_selftest0001")
        t.expect(try Credentials.stored(), "hf_selftest0001")
        try Credentials.store("hf_selftest0002")
        t.expect(try Credentials.stored(), "hf_selftest0002")
        t.expect(try Credentials.removeAll(), 1)
        t.expect(try Credentials.stored(), nil)
      }
    }
  }

  // MARK: Unused models

  static func unused(_ t: Runner) {
    t.test("unused: models on disk the new setting doesn't use, with sizes") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let home = TMSMHome(root: dir)
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      for id in ["asr-a", "asr-b", "spk-a"] {
        try write(
          String(repeating: "x", count: 5000),
          home.models(engine: "test").appendingPathComponent("\(id)/weights.bin"))
      }
      let fast = try catalogue.preset(named: "fast")
      let unused = setup.unusedModels(keeping: fast)
      t.expect(unused.map(\.id), ["asr-b"])
      t.expect((unused.first?.bytes ?? 0) >= 5000, "size counted")
      try setup.remove(unused)
      t.expect(exists(home.models(engine: "test").appendingPathComponent("asr-b")), false)
      t.expect(exists(home.models(engine: "test").appendingPathComponent("asr-a")), true)
      t.expect(setup.unusedModels(keeping: fast).isEmpty, "nothing left to offer")
    }

    t.test("unused: the pre-pin Nemotron folder is offered as an old download") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let home = TMSMHome(root: dir)
      let old = home.models(engine: "fluidaudio").appendingPathComponent("nemotron-3-diarization")
      try write("x", old.appendingPathComponent("offline/model.bin"))
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      let unused = setup.unusedModels(keeping: try catalogue.preset(named: "fast"))
      t.expect(unused.map(\.id), ["nemotron-3 (old download)"])
      t.expect(unused.first?.paths, [old.standardizedFileURL])
    }

    t.test("unused: a folder that holds a kept model is never offered") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let home = TMSMHome(root: dir)
      let shared = home.models(engine: "test").appendingPathComponent("repo")
      let outer = CatalogueEntry(
        id: "outer", name: "Outer", engine: "test", languages: [], downloadMB: 1, license: "MIT",
        gated: false, factory: .speakers { _ in Silent() }, storage: { _ in [shared] })
      let inner = CatalogueEntry(
        id: "inner", name: "Inner", engine: "test", languages: [], downloadMB: 1, license: "MIT",
        gated: false, factory: .speakers { _ in Silent() },
        storage: { _ in [shared.appendingPathComponent("inner")] })
      let cat = Catalogue(
        [
          EngineRegistration(
            engine: "test", entries: [entry("asr-a", .transcription), outer, inner])
        ], presets: [])
      try write("x", shared.appendingPathComponent("inner/model"))
      let keep = Preset(
        name: "x", transcription: "asr-a", speakers: "inner", summary: "", ramGB: nil)
      t.expect(
        ModelSetup(home: home, catalogue: cat, environment: [:]).unusedModels(keeping: keep)
          .map(\.id), [])
    }

    t.test("setup: apply saves the choice and deletes unused models when asked") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let home = TMSMHome(root: dir)
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      try write("x", home.models(engine: "test").appendingPathComponent("asr-b/w"))
      let console = Scripted([], interactive: false)
      try blocking {
        try await setup.apply(
          Config(preset: "fast"), console: console, progress: .silent, deleteUnused: true)
      }
      t.expect(try Config.load(from: home.configFile), Config(preset: "fast"))
      t.expect(exists(home.models(engine: "test").appendingPathComponent("asr-b")), false)
    }
  }

  // MARK: PATH line

  static func pathLine(_ t: Runner) {
    t.test("path: the login profile of the user's shell") {
      let zsh = Installer(environment: ["HOME": "/h", "SHELL": "/bin/zsh"])
      t.expect(zsh.profile.path, "/h/.zprofile")
      t.expect(
        Installer(environment: ["HOME": "/h", "SHELL": "/bin/bash"]).profile.path,
        "/h/.bash_profile")
      t.expect(
        Installer(environment: ["HOME": "/h", "SHELL": "/usr/bin/fish"]).profile.path,
        "/h/.config/fish/conf.d/tmsm.fish")
      t.expect(
        Installer(environment: ["HOME": "/h", "SHELL": "/bin/ksh"]).profile.path, "/h/.profile"
      )
      t.expect(zsh.programFolder.path, "/h/.tmsm")
    }

    t.test("path: one marked line, added once, removed with nothing else") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/zsh"])
      let profile = dir.appendingPathComponent(".zprofile")
      let user = "export EDITOR=vim\n# my tmsm notes\nalias tmsm2=echo # tmsm\n"
      try write(user, profile)
      t.expect(try installer.addPathLine(), true)
      t.expect(try installer.addPathLine(), false, "second install adds nothing")
      t.expect(read(profile), user + Installer.pathLine + "\n")
      t.expect(try installer.removePathLines().map(\.lastPathComponent), [".zprofile"])
      t.expect(read(profile), user, "the user's lines stay, even ones that mention tmsm")
    }

    t.test("path: after a change of shell the line moves; still one line") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      try write("export A=1\n", dir.appendingPathComponent(".bash_profile"))
      try Installer(environment: ["HOME": dir.path, "SHELL": "/bin/bash"]).addPathLine()
      let zsh = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/zsh"])
      t.expect(try zsh.addPathLine(), true)
      t.expect(read(dir.appendingPathComponent(".bash_profile")), "export A=1\n")
      t.expect(read(dir.appendingPathComponent(".zprofile")), Installer.pathLine + "\n")
      t.expect(try zsh.addPathLine(), false)
    }

    t.test("path: an unreadable profile is never overwritten") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let profile = dir.appendingPathComponent(".zprofile")
      let latin1 = Data([0x65, 0x78, 0x70, 0xE9, 0x0A])  // not UTF-8
      try latin1.write(to: profile)
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/zsh"])
      do {
        try installer.addPathLine()
        t.fail("expected an error")
      } catch {}
      t.expect(try Data(contentsOf: profile), latin1)
    }

    t.test("path: a symlinked profile stays a symlink") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let target = dir.appendingPathComponent("dotfiles/zprofile")
      try write("export A=1\n", target)
      let profile = dir.appendingPathComponent(".zprofile")
      try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/zsh"])
      try installer.addPathLine()
      t.expect(read(target), "export A=1\n" + Installer.pathLine + "\n")
      try installer.removePathLines()
      t.expect(read(target), "export A=1\n")
      t.expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: profile.path)) != nil, "link")
    }

    t.test("path: a profile that held only our line goes with it") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/bash"])
      try installer.addPathLine()
      t.expect(exists(dir.appendingPathComponent(".bash_profile")), true)
      try installer.removePathLines()
      t.expect(exists(dir.appendingPathComponent(".bash_profile")), false)
    }

    t.test("path: the line is valid sh and puts ~/.tmsm first") {
      let out = try Updater.run(
        "/bin/sh", ["-c", "HOME=/h; PATH=/usr/bin; \(Installer.pathLine)\necho \"$PATH\""],
        in: nil)
      t.expect(out, "/h/.tmsm:/usr/bin\n")
    }
  }

  // MARK: Program folder

  static func program(_ t: Runner) {
    t.test("install: copies only program files, swaps in a new version") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let release = dir.appendingPathComponent("tmsm-9.9.9-macos-arm64")
      for name in ["tmsm", "NOTICE", "mlx.metallib", "x.bundle/Info.plist", "notes.txt"] {
        try write(name, release.appendingPathComponent(name))
      }
      let home = dir.appendingPathComponent("home")
      let installer = Installer(environment: ["HOME": home.path])
      t.expect(
        try Installer.programItems(in: release), ["NOTICE", "mlx.metallib", "tmsm", "x.bundle"])
      t.expect(try installer.installProgram(from: release), true)
      t.expect(
        try FileManager.default.contentsOfDirectory(atPath: installer.programFolder.path).sorted(),
        [".tmsm-program", "NOTICE", "mlx.metallib", "tmsm", "x.bundle"])
      try write("v2", release.appendingPathComponent("tmsm"))
      try FileManager.default.removeItem(at: release.appendingPathComponent("NOTICE"))
      try installer.installProgram(from: release)
      t.expect(read(installer.executable), "v2")
      t.expect(exists(installer.programFolder.appendingPathComponent("NOTICE")), false)
      t.expect(
        try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(), [".tmsm"],
        "no staging folders left")
      t.expect(
        try installer.installProgram(from: installer.programFolder), false,
        "running the installed copy installs nothing")
    }

    t.test("install: a folder without tmsm, or a ~/.tmsm with foreign files, is refused") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      expectError(t, SetupError.notAProgramFolder(dir.path)) {
        _ = try Installer.programItems(in: dir)
      }
      let installer = Installer(environment: ["HOME": dir.path])
      try write("mine", installer.programFolder.appendingPathComponent("diary.txt"))
      try fakeInstall(installer)
      let release = dir.appendingPathComponent("release")
      try write("tmsm", release.appendingPathComponent("tmsm"))
      expectError(t, SetupError.foreignFiles(installer.programFolder.path, ["diary.txt"])) {
        try installer.installProgram(from: release)
      }
      t.expect(read(installer.programFolder.appendingPathComponent("diary.txt")), "mine")
    }
  }

  static func ownership(_ t: Runner) {
    t.test("install: a ~/.tmsm or staging folder without manifest is not ours") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path])
      let release = dir.appendingPathComponent("release")
      try write("tmsm", release.appendingPathComponent("tmsm"))
      // A stranger's .tmsm.new with names that look like program files.
      let stray = dir.appendingPathComponent(".tmsm.new")
      try write("mine", stray.appendingPathComponent("README.md"))
      expectError(t, SetupError.notOwned(stray.path)) {
        try installer.installProgram(from: release)
      }
      t.expect(read(stray.appendingPathComponent("README.md")), "mine")
      try FileManager.default.removeItem(at: stray)
      try write("mine", installer.programFolder.appendingPathComponent("README.md"))
      expectError(t, SetupError.notOwned(installer.programFolder.path)) {
        try installer.installProgram(from: release)
      }
    }

    t.test("install: a legacy ~/.tmsm (ours, no manifest) is taken over") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path])
      try write("old", installer.executable)
      chmod(installer.executable.path, 0o755)
      try write(
        "tmsm — transcribe multi-speaker audio on macOS\n",
        installer.programFolder.appendingPathComponent("NOTICE"))
      let release = dir.appendingPathComponent("release")
      try write("new", release.appendingPathComponent("tmsm"))
      t.expect(try installer.installProgram(from: release), true)
      t.expect(read(installer.executable), "new")
      t.expect(exists(installer.manifest), true)
    }

    t.test("path: bash gets the first login file that exists, and the manifest records it") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      try write("PATH=/opt/bin:$PATH\n", dir.appendingPathComponent(".profile"))
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/bin/bash"])
      t.expect(installer.profile.lastPathComponent, ".profile")
      try fakeInstall(installer)
      try installer.addPathLine()
      t.expect(exists(dir.appendingPathComponent(".bash_profile")), false, "would hide .profile")
      t.expect(
        read(dir.appendingPathComponent(".profile")),
        "PATH=/opt/bin:$PATH\n" + Installer.pathLine + "\n")
      t.expect(read(installer.manifest)?.contains("profile \(dir.path)/.profile"), true)
      try write("", dir.appendingPathComponent(".bash_login"))
      t.expect(installer.profile.lastPathComponent, ".bash_login", ".bash_login comes first")
    }

    t.test("path: fish gets an owned conf.d snippet; uninstall removes it and its new folders") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path, "SHELL": "/opt/homebrew/bin/fish"])
      try fakeInstall(installer)
      try write("export A=1\n" + Installer.pathLine + "\n", dir.appendingPathComponent(".zprofile"))
      t.expect(try installer.addPathLine(), true)
      t.expect(read(installer.fishFile), Installer.fishSnippet)
      t.expect(read(dir.appendingPathComponent(".zprofile")), "export A=1\n", "the line moved")
      t.expect(try installer.addPathLine(), false)
      try installer.removePathLines()
      t.expect(exists(dir.appendingPathComponent(".config")), false, "created folders go")

      try write("set -x EDITOR vim\n", installer.fishFile)  // someone else's tmsm.fish
      expectError(t, SetupError.foreignFiles(installer.fishFile.path, ["tmsm.fish"])) {
        try installer.addPathLine()
      }
      t.expect(read(installer.fishFile), "set -x EDITOR vim\n")
    }

    t.test("path: the fish snippet is valid fish") {
      guard let fish = AudioDecoder.findExecutable("fish", path: "/opt/homebrew/bin:/usr/local/bin")
      else { return }
      let out = try Updater.run(
        fish.path,
        [
          "--no-config", "-c",
          "set -gx HOME /h; set -gx PATH /usr/bin; \(Installer.fishSnippet)\necho $PATH",
        ],
        in: nil)
      t.expect(out, "/h/.tmsm /usr/bin\n")
    }
  }

  // MARK: Uninstall

  static func uninstall(_ t: Runner) {
    t.test("uninstall: removes home, program, PATH line, system folders; nothing else") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let userHome = dir.appendingPathComponent("home")
      let installer = Installer(environment: ["HOME": userHome.path, "SHELL": "/bin/zsh"])
      let home = TMSMHome(root: userHome.appendingPathComponent("Library/Application Support/tmsm"))
      let caches = userHome.appendingPathComponent("Library/Caches/tmsm")
      let other = userHome.appendingPathComponent("Library/Caches/other-app/keep")
      try write("{}", home.configFile)
      try write("", home.root.appendingPathComponent(Uninstaller.markerName))
      try write("w", home.models(engine: "x").appendingPathComponent("m"))
      try write("c", caches.appendingPathComponent("e5"))
      try write("keep", other)
      try write("export A=1\n", userHome.appendingPathComponent(".zprofile"))
      try fakeInstall(installer)
      try installer.addPathLine()

      let uninstaller = Uninstaller(home: home, installer: installer, leftovers: [caches])
      // The real Keychain stays out of the test.
      let plan = uninstaller.plan().filter { $0 != .keychain }
      t.expect(plan.count, 4)
      let errors = uninstaller.run(plan)
      t.expect(errors.count, 0, "\(errors)")
      for gone in [home.root, installer.programFolder, caches] {
        t.expect(exists(gone), false, gone.path)
      }
      t.expect(read(other), "keep")
      t.expect(read(userHome.appendingPathComponent(".zprofile")), "export A=1\n")
      t.expect(exists(userHome.appendingPathComponent("Library/Caches")), true, "not empty")
    }

    t.test("uninstall: empty parents of the default home go only while empty") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let installer = Installer(environment: ["HOME": dir.path])
      let support = dir.appendingPathComponent("Library/Application Support")
      let home = TMSMHome(root: support.appendingPathComponent("tmsm"))
      try write("{}", home.configFile)
      try write("", home.root.appendingPathComponent(Uninstaller.markerName))
      let uninstaller = Uninstaller(home: home, installer: installer, leftovers: [])
      t.expect(uninstaller.run([.home(home.root)]).count, 0)
      t.expect(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

      try write("{}", home.configFile)
      try write("", home.root.appendingPathComponent(Uninstaller.markerName))
      try write("x", support.appendingPathComponent("Other App/data"))
      t.expect(uninstaller.run([.home(home.root)]).count, 0)
      t.expect(read(support.appendingPathComponent("Other App/data")), "x")

      let custom = TMSMHome(root: dir.appendingPathComponent("a/b/tmsm"))
      try write("{}", custom.configFile)
      try write("", custom.root.appendingPathComponent(Uninstaller.markerName))
      t.expect(
        Uninstaller(home: custom, installer: installer, leftovers: []).run([.home(custom.root)])
          .count, 0)
      t.expect(exists(dir.appendingPathComponent("a/b")), true, "a custom home's parents stay")
    }

    t.test("uninstall: a TMSM_HOME holding other files is left alone, the rest still goes") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let shared = dir.appendingPathComponent("Documents")
      try write("mine", shared.appendingPathComponent("thesis.pages"))
      try write("{}", shared.appendingPathComponent("config.json"))
      try write("", shared.appendingPathComponent(Uninstaller.markerName))
      let installer = Installer(environment: ["HOME": dir.path])
      try fakeInstall(installer)
      let uninstaller = Uninstaller(
        home: TMSMHome(root: shared), installer: installer, leftovers: [])
      let errors = uninstaller.run(uninstaller.plan().filter { $0 != .keychain })
      t.expect(
        errors.map { ($0 as? SetupError) },
        [SetupError.foreignFiles(shared.path, ["thesis.pages"])])
      t.expect(read(shared.appendingPathComponent("thesis.pages")), "mine")
      t.expect(exists(installer.programFolder), false, "the program still goes")
    }
    t.test("uninstall: a TMSM_HOME tmsm did not create is never removed") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      // Someone's model project that happens to look like a tmsm home.
      let project = TMSMHome(root: dir.appendingPathComponent("project"))
      try write("{}", project.configFile)
      try write("weights", project.models.appendingPathComponent("mine.bin"))
      let env = ["HOME": dir.appendingPathComponent("home").path, "TMSM_HOME": project.root.path]
      try Uninstaller.claim(project, environment: env)
      t.expect(exists(project.root.appendingPathComponent(Uninstaller.markerName)), false)
      let uninstaller = Uninstaller(
        home: project, installer: Installer(environment: env), leftovers: [])
      expectError(t, SetupError.notTMSMHome(project.root.path)) {
        if let error = uninstaller.run([.home(project.root)]).first { throw error }
      }
      t.expect(read(project.models.appendingPathComponent("mine.bin")), "weights")
    }

    t.test("uninstall: tmsm marks a home it creates, and the default home") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let fresh = TMSMHome(root: dir.appendingPathComponent("new/tmsm"))
      try Uninstaller.claim(fresh, environment: ["TMSM_HOME": fresh.root.path])
      t.expect(exists(fresh.root.appendingPathComponent(Uninstaller.markerName)), true, "new")
      let env = ["HOME": dir.path]
      let standard = TMSMHome.resolve(environment: env)
      try write("{}", standard.configFile)  // exists already, but it is the default location
      try Uninstaller.claim(standard, environment: env)
      t.expect(
        exists(standard.root.appendingPathComponent(Uninstaller.markerName)), true, "default")
    }
  }

  // MARK: Recovery uninstall (scripts/uninstall.sh)

  static func recovery(_ t: Runner) {
    let script = repo.appendingPathComponent("scripts/uninstall.sh")

    /// Installs the way `tmsm install` does, into a temp HOME, for `shell`.
    func installed(_ dir: URL, shell: String) throws -> (Installer, TMSMHome) {
      let home = dir.appendingPathComponent("home")
      let env = ["HOME": home.path, "SHELL": shell]
      let installer = Installer(environment: env)
      let release = dir.appendingPathComponent("release")
      for name in ["tmsm", "NOTICE", "uninstall.sh"] {
        try write(name, release.appendingPathComponent(name))
      }
      try installer.installProgram(from: release)
      try installer.addPathLine()
      let tmsmHome = TMSMHome.resolve(environment: env)
      try Uninstaller.claim(tmsmHome, environment: env)
      try write("{}", tmsmHome.configFile)
      try write("w", tmsmHome.models.appendingPathComponent("x/m"))
      return (installer, tmsmHome)
    }

    func runScript(_ dir: URL, _ extra: [String: String] = [:]) throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [script.path]
      var env = [
        "HOME": dir.appendingPathComponent("home").path, "PATH": "/usr/bin:/bin:/usr/sbin",
        "TMSM_SKIP_KEYCHAIN": "1",
        "TMSM_ACCOUNT_HOME": dir.appendingPathComponent("account").path,
      ]
      env.merge(extra) { $1 }
      process.environment = env
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }

    for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
      t.test("recovery: uninstall.sh leaves an empty HOME after a \(shell) install") {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try installed(dir, shell: shell)
        let caches = dir.appendingPathComponent("account/Library/Caches/tmsm/x")
        try write("c", caches)
        t.expect(try runScript(dir), 0)
        let left = try FileManager.default.contentsOfDirectory(
          atPath: dir.appendingPathComponent("home").path)
        t.expect(left, [], "left in HOME")
        t.expect(exists(caches), false, "account cache")
      }
    }

    t.test("recovery: uninstall.sh refuses what isn't provably tmsm's, removes the rest") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let (installer, tmsmHome) = try installed(dir, shell: "/bin/zsh")
      try write("mine", installer.programFolder.appendingPathComponent("diary.txt"))
      try write("mine", tmsmHome.root.appendingPathComponent("thesis.pages"))
      let stray = dir.appendingPathComponent("home/.tmsm.new")
      try write("mine", stray.appendingPathComponent("README.md"))
      // A profile kept in a dotfiles folder, linked in.
      let target = dir.appendingPathComponent("dotfiles/zprofile")
      let profile = dir.appendingPathComponent("home/.zprofile")
      try write("export A=1\n" + Installer.pathLine + "\n", target)
      try FileManager.default.removeItem(at: profile)
      try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)

      t.expect(try runScript(dir), 1, "exit 1 when something was left alone")
      t.expect(read(installer.programFolder.appendingPathComponent("diary.txt")), "mine")
      t.expect(read(tmsmHome.root.appendingPathComponent("thesis.pages")), "mine")
      t.expect(read(stray.appendingPathComponent("README.md")), "mine")
      t.expect(read(target), "export A=1\n", "line removed through the link")
      t.expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: profile.path)) != nil,
        "still a link")
    }

    t.test("recovery: a TMSM_HOME tmsm did not create is left alone") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let project = dir.appendingPathComponent("project")
      try write("{}", project.appendingPathComponent("config.json"))
      try write("w", project.appendingPathComponent("models/mine.bin"))
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
      t.expect(try runScript(dir, ["TMSM_HOME": project.path]), 1)
      t.expect(read(project.appendingPathComponent("models/mine.bin")), "w")
    }
  }

  // MARK: Update

  static func update(_ t: Runner) {
    t.test("update: versions") {
      t.expect(Updater.version(fromTagURL: "https://github.com/o/r/releases/tag/v0.2.0\n"), "0.2.0")
      t.expect(Updater.version(fromTagURL: "https://github.com/o/r/releases"), nil)
      t.expect(Updater.version(fromTagURL: "https://github.com/o/r/releases/tag/vnext"), nil)
      t.expect(Updater.isNewer("0.10.0", than: "0.9.1"), true)
      t.expect(Updater.isNewer("0.1.0", than: "0.1.0"), false)
      t.expect(Updater.isNewer("0.0.9", than: "0.1.0"), false)
      t.expect(Updater.assetName("0.1.0"), "tmsm-0.1.0-macos-arm64.tar.gz")
    }

    t.test("update: downloads, checks SHA256SUMS, unpacks; a bad hash stops it") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let releases = dir.appendingPathComponent("releases")
      let assets = releases.appendingPathComponent("download/v9.9.9")
      let stage = dir.appendingPathComponent("stage")
      try write("#!/bin/sh\n", stage.appendingPathComponent("tmsm-9.9.9-macos-arm64/tmsm"))
      try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
      let asset = Updater.assetName("9.9.9")
      _ = try Updater.run(
        "/usr/bin/tar",
        ["-czf", assets.appendingPathComponent(asset).path, "tmsm-9.9.9-macos-arm64"],
        in: stage)
      let sum = try Updater.run("/usr/bin/shasum", ["-a", "256", asset], in: assets)
      try write("0000  other.tar.gz\n" + sum, assets.appendingPathComponent("SHA256SUMS"))

      let updater = Updater(environment: ["TMSM_RELEASES": releases.absoluteString])
      let into = dir.appendingPathComponent("into")
      try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
      let unpacked = try updater.fetch("9.9.9", into: into)
      t.expect(read(unpacked.appendingPathComponent("tmsm")), "#!/bin/sh\n")

      try write(
        String(repeating: "0", count: 64) + "  \(asset)\n",
        assets.appendingPathComponent("SHA256SUMS"))
      let again = dir.appendingPathComponent("again")
      try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
      expectError(t, SetupError.checksum(asset)) { _ = try updater.fetch("9.9.9", into: again) }
      t.expect(
        exists(again.appendingPathComponent("tmsm-9.9.9-macos-arm64")), false, "not unpacked")
    }
  }

  // MARK: Pipes

  static func pipes(_ t: Runner) {
    t.test("pipes: the format of stdin comes from its first bytes") {
      func sniff(_ bytes: [UInt8]) -> String? { AudioInput.sniff(Data(bytes)) }
      func ascii(_ text: String, pad: Int = 0) -> [UInt8] {
        Array(text.utf8) + [UInt8](repeating: 0, count: pad)
      }
      t.expect(sniff(ascii("OggS", pad: 8)), "ogg")
      t.expect(sniff(ascii("fLaC")), "flac")
      t.expect(sniff(ascii("RIFF") + [1, 2, 3, 4] + ascii("WAVE")), "wav")
      t.expect(sniff(ascii("RIFF") + [1, 2, 3, 4] + ascii("AVI ")), nil)
      t.expect(sniff([0, 0, 0, 0x20] + ascii("ftypM4A ")), "m4a")
      t.expect(sniff([0, 0, 0, 0x14] + ascii("ftypqt  ")), "mov")
      t.expect(sniff([0, 0, 0, 0x18] + ascii("ftypisom")), "m4a")
      t.expect(sniff(ascii("ID3") + [4, 0]), "mp3")
      t.expect(sniff([0xFF, 0xFB, 0x90]), "mp3")
      t.expect(sniff([0xFF, 0xF1, 0x50]), "aac")
      t.expect(sniff([0x1A, 0x45, 0xDF, 0xA3]), "webm")
      t.expect(sniff(ascii("hello")), nil)
      t.expect(sniff([]), nil)
    }

    t.test("pipes: stdin is copied whole into the run folder, empty input is an error") {
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let pipe = Pipe()
      let body = Data("fLaC".utf8) + Data(repeating: 7, count: 3 << 20)
      let writer = Thread {
        pipe.fileHandleForWriting.write(body)
        try? pipe.fileHandleForWriting.close()
      }
      writer.start()
      let file = try AudioInput.copy(from: pipe.fileHandleForReading, into: dir)
      t.expect(file.lastPathComponent, "stdin.flac")
      t.expect(try Data(contentsOf: file), body, "every byte, across chunks")
      t.expect(
        try FileManager.default.contentsOfDirectory(atPath: dir.path), ["stdin.flac"],
        "no partial file left")

      let empty = Pipe()
      try empty.fileHandleForWriting.close()
      expectError(t, TMSMError.emptyAudio("stdin")) {
        _ = try AudioInput.copy(from: empty.fileHandleForReading, into: dir)
      }
    }

    t.test("pipes: - for input and output parse; names for heading and file") {
      let piped = try RunOptions.parse(["-", "--output", "-"])
      t.expect(piped.readsStdin, true)
      t.expect(piped.writesStdout, true)
      t.expect(Pipeline.title(piped), "stdin")
      let named = try RunOptions.parse(["-", "--name", "Journal 2026/11/08"])
      t.expect(Pipeline.title(named), "Journal 2026/11/08")
      let source = Pipeline.nameSource(named, input: URL(fileURLWithPath: "/tmp/stdin.m4a"))
      t.expect(
        OutputFile.target(
          input: source, output: nil, desktop: URL(fileURLWithPath: "/d"),
          cwd: URL(fileURLWithPath: "/")
        ).path, "/d/Journal 2026-11-08.md")
      let file = try RunOptions.parse(["~/memo.v2.opus"])
      t.expect(Pipeline.title(file), "memo.v2.opus")
      let input = URL(fileURLWithPath: "/x/memo.v2.opus")
      t.expect(Pipeline.nameSource(file, input: input), input, "a file keeps its own name")
    }

    t.test("markdown: headings escape all markup, turn text only what changes rendering") {
      t.expect(
        Transcript.escapeHeading("[private](https://example.org) *x* <b>#1</b>.m4a"),
        "\\[private\\](https://example.org) \\*x\\* \\<b\\>\\#1\\</b\\>.m4a")
      t.expect(Transcript.escapeHeading("memo 2026-11-08.opus"), "memo 2026-11-08.opus")
      t.expect(Transcript.escapeHeading("a\nb"), "a b")
      t.expect(
        Transcript.escapeText("Okay, it's 5 p.m. - see `ls` <here> [1] and_this *too*."),
        "Okay, it's 5 p.m. - see \\`ls\\` \\<here> \\[1\\] and_this *too*.")
      t.expect(Transcript.escapeText("# not a heading"), "\\# not a heading")
      t.expect(Transcript.escapeText("1. not a list"), "1\\. not a list")
      t.expect(Transcript.escapeText("2026 was good."), "2026 was good.")
      let md = Transcript(
        title: "[x](y).m4a", turns: [Turn(speaker: 1, text: "<script>", start: 0, end: 1)]
      ).markdown
      t.expect(md, "# \\[x\\](y).m4a\n\nSpeaker 1: \\<script>\n")
    }

    t.test("flags: a wrong --preset or --language is a usage error (exit 64)") {
      for bad in [
        ["memo.m4a", "--preset", "typo"], ["memo.m4a", "--language", "german"],
        ["memo.m4a", "--language", "d"], ["memo.m4a", "--language", "de-"],
      ] {
        do {
          _ = try RunOptions.parse(bad)
          t.fail("accepted \(bad)")
        } catch {
          t.expect(RunOptions.exitCode(for: error).rawValue, 64, "\(bad)")
        }
      }
      for good in [
        ["m", "--preset", "Accurate"], ["m", "--language", "de-DE"],
        ["m", "--language", "pt_BR"], ["m", "--language", "AUTO"], ["m", "--preset", "individual"],
      ] {
        t.expect((try? RunOptions.parse(good)) != nil, "rejected \(good)")
      }
    }

    t.test("speakers 1 on a turn-wise preset: no labelling, turns decoded together") {
      final class Calls: @unchecked Sendable { var log: [String] = [] }
      let calls = Calls()
      struct ASR: TranscriptionEngine {
        let calls: Calls
        func transcribe(_ audio: Audio, language: String?, progress: TMSM.Progress) async throws
          -> [Word]
        {
          calls.log.append("whole")
          return [Word("hallo", 0, 0.5)]
        }
        func transcribe(segments: [Audio], language: String?, progress: TMSM.Progress)
          async throws -> [[Word]]
        {
          calls.log.append("segments \(segments.count)")
          return segments.map { _ in [Word("hallo", 0, 0.5)] }
        }
      }
      struct Labeller: SpeakerEngine {
        let calls: Calls
        func label(_ audio: Audio, maxSpeakers: Int, progress: TMSM.Progress) async throws
          -> SpeakerTrack
        {
          calls.log.append("label")
          return SpeakerTrack(segments: [SpeakerSegment(0, 0, audio.duration)])
        }
      }
      let cat = Catalogue(
        [
          EngineRegistration(
            engine: "test",
            entries: [
              CatalogueEntry(
                id: "asr", name: "ASR", engine: "test", languages: ["de"], downloadMB: 1,
                license: "", gated: false, factory: .transcription { _ in ASR(calls: calls) },
                storage: { _ in [] }),
              CatalogueEntry(
                id: "spk", name: "SPK", engine: "test", languages: [], downloadMB: 1, license: "",
                gated: false, factory: .speakers { _ in Labeller(calls: calls) },
                storage: { _ in [] }),
            ])
        ],
        presets: [
          Preset(
            name: "tw", transcription: "asr", speakers: "spk", summary: "", ramGB: nil,
            strategy: .turnwise)
        ])
      let dir = tempFolder()
      defer { try? FileManager.default.removeItem(at: dir) }
      let home = TMSMHome(root: dir.appendingPathComponent("home"))
      try Config(preset: "tw").save(to: home.configFile)
      let wav = dir.appendingPathComponent("tone.wav")
      try SetupCases.wav(seconds: 2).write(to: wav)
      let pipeline = Pipeline(home: home, catalogue: cat, environment: [:], cwd: dir)
      final class Box: @unchecked Sendable { var result: RunResult? }
      let box = Box()
      try blocking {
        box.result = try await pipeline.run(
          try RunOptions.parse([wav.path, "--speakers", "1", "--language", "de", "-o", "-"]),
          progress: .silent)
      }
      t.expect(calls.log, ["segments 1"], "no labelling, no whole-file decode")
      t.expect(box.result?.speakerModel, nil)
      t.expect(box.result?.markdown, "# tone.wav\n\nSpeaker 1: hallo\n")
    }

    t.test("pipes: --json with --output - carries the Markdown, no path") {
      let result = RunResult(
        output: nil, markdown: "# stdin\n\nSpeaker 1: Hi.\n", input: "-", preset: "fast",
        transcriptionModel: "a", speakerModel: nil, language: "auto", speakers: 1,
        durationSeconds: 1, words: 1)
      let object =
        try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any] ?? [:]
      t.expect(object["output"] == nil, "no output key")
      t.expect(object["markdown"] as? String, "# stdin\n\nSpeaker 1: Hi.\n")
    }
  }

  // MARK: Docs match the binary

  /// The repo root, from this file's path.
  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// The tmsm built beside this selftest (scripts/check.sh builds both).
  static var binary: URL? {
    guard let me = Bundle.main.executableURL else { return nil }
    let url = me.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(
      "tmsm")
    return exists(url) ? url : nil
  }

  /// Blocks in a Markdown file written as `<!-- tmsm <args> -->` followed by a fenced block.
  static func quotedOutputs(_ markdown: String) -> [(args: [String], text: String)] {
    var result: [(args: [String], text: String)] = []
    let lines = markdown.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("<!-- tmsm"), line.hasSuffix("-->"), i + 1 < lines.count,
        lines[i + 1].hasPrefix("```")
      {
        let args = line.dropFirst("<!-- tmsm".count).dropLast("-->".count)
          .split(separator: " ").map(String.init)
        var body: [String] = []
        var j = i + 2
        while j < lines.count, !lines[j].hasPrefix("```") {
          body.append(lines[j])
          j += 1
        }
        result.append((args, body.joined(separator: "\n")))
        i = j
      }
      i += 1
    }
    return result
  }

  /// Every `--flag` mentioned in a text.
  static func flags(_ text: String) -> Set<String> {
    let regex = try! NSRegularExpression(pattern: "(?<![\\w-])--[a-z][a-z-]*")
    let range = NSRange(text.startIndex..., in: text)
    return Set(
      regex.matches(in: text, range: range).compactMap { Range($0.range, in: text) }
        .map { String(text[$0]) })
  }

  static func docs(_ t: Runner) {
    t.test("docs: quoted tmsm output in docs/cli.md and README.md matches the binary") {
      guard let binary else {
        t.fail("no tmsm beside selftest; run `swift build` first")
        return
      }
      let emptyHome = tempFolder()
      defer { try? FileManager.default.removeItem(at: emptyHome) }
      var helpText = ""
      for command in ["", "transcribe", "setup", "install", "update", "uninstall"] {
        let args = (command.isEmpty ? [] : [command]) + ["--help"]
        helpText += try Updater.run(binary.path, args, in: nil)
      }
      var quotes = 0
      for doc in ["docs/cli.md", "README.md"] {
        guard let text = read(repo.appendingPathComponent(doc)) else {
          t.fail("\(doc) is missing")
          continue
        }
        for (args, quoted) in quotedOutputs(text) {
          quotes += 1
          let process = Process()
          process.executableURL = binary
          process.arguments = args
          process.environment = ["TMSM_HOME": emptyHome.path, "PATH": "/usr/bin:/bin"]
          let pipe = Pipe()
          process.standardOutput = pipe
          try process.run()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          let actual = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
          t.expect(
            quoted.trimmingCharacters(in: .newlines) == actual,
            "\(doc): `tmsm \(args.joined(separator: " "))` differs; run scripts/docs-reference.sh")
        }
        // Only lines about tmsm: `xcode-select --install`, the install line's curl flags and
        // the repo scripts' flags are not ours to check.
        let ours = text.components(separatedBy: "\n").filter {
          $0.contains("tmsm") && !$0.contains("curl ") && !$0.contains("scripts/")
        }
        let unknown = flags(ours.joined(separator: "\n")).subtracting(flags(helpText))
        t.expect(unknown.isEmpty, "\(doc) names flags tmsm doesn't have: \(unknown.sorted())")
      }
      t.expect(quotes >= 7, "the docs quote every --help and setup --list (found \(quotes))")
      let documented = flags(read(repo.appendingPathComponent("docs/cli.md")) ?? "")
      let missing = flags(helpText).subtracting(documented).subtracting(["--help"])
      t.expect(missing.isEmpty, "docs/cli.md misses flags: \(missing.sorted())")
    }
  }
}
