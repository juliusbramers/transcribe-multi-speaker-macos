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
    uninstall(t)
    update(t)
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
  static let catalogue = Catalogue([
    EngineRegistration(
      engine: "test",
      entries: [
        entry("asr-a", .transcription, mb: 400), entry("asr-b", .transcription, mb: 700),
        entry("asr-gated", .transcription, gated: true),
        entry("spk-a", .speakers, mb: 90), entry("spk-b", .speakers, mb: 190),
      ],
      presets: [
        Preset(name: "fast", transcription: "asr-a", speakers: "spk-a", summary: "A"),
        Preset(name: "default", transcription: "asr-b", speakers: "spk-b", summary: "B"),
      ])
  ])

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
      // choices: fast, default, individual; transcription: asr-a, asr-b, asr-gated.
      let console = Scripted(["3", "1", ""])
      t.expect(
        try setup.ask(console, current: Config()),
        Config(preset: "individual", transcription: "asr-a", speakers: "spk-b"),
        "Enter keeps the current preset's speaker model")
      t.expect(console.said.contains { $0.contains("gated") }, "gated models are marked")
    }

    t.test("wizard and --list show catalogue figures, not hand-written ones") {
      let console = Scripted(["1"])
      _ = try setup.ask(console, current: Config())
      t.expect(console.said.contains { $0.contains("fast: A, 490 MB download") }, "fast line")
      let list = setup.listing(current: Config(preset: "fast"))
      t.expect(list.contains("* fast        asr-a + spk-a, 490 MB download"), "fast marked")
      t.expect(list.contains("  default     asr-b + spk-b, 890 MB download"), "default")
      t.expect(list.contains("asr-gated  ASR-GATED, 100 MB, 1 languages, MIT, gated"), "gated")
      t.expect(
        setup.listing(current: Config()).contains("* default"), "no config: default is in use")
    }
  }

  // MARK: Token

  static func token(_ t: Runner) {
    let home = TMSMHome(root: URL(fileURLWithPath: "/nonexistent/tmsm-home"))
    let gated = Preset(
      name: "individual", transcription: "asr-gated", speakers: "spk-a", summary: "")

    t.test("token: HF_TOKEN means nothing is asked") {
      let setup = ModelSetup(
        home: home, catalogue: catalogue, environment: ["HF_TOKEN": "hf_abcdefgh123"])
      let console = Scripted([])
      try setup.ensureToken(for: gated, console: console)
      t.expect(console.said.isEmpty, "no question")
    }

    t.test("token: no token and no terminal fails with a hint, ungated needs none") {
      // Holds only if no real token is stored under service "tmsm"; skip otherwise.
      guard Credentials.stored() == nil else { return }
      let setup = ModelSetup(home: home, catalogue: catalogue, environment: [:])
      expectError(t, SetupError.tokenMissing("ASR-GATED")) {
        try setup.ensureToken(for: gated, console: Scripted([], interactive: false))
      }
      try setup.ensureToken(
        for: catalogue.preset(named: "fast"), console: Scripted([], interactive: false))
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
        t.expect(Credentials.stored(), "hf_selftest0001")
        try Credentials.store("hf_selftest0002")
        t.expect(Credentials.stored(), "hf_selftest0002")
        t.expect(try Credentials.removeAll(), 1)
        t.expect(Credentials.stored(), nil)
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
      let cat = Catalogue([
        EngineRegistration(
          engine: "test", entries: [entry("asr-a", .transcription), outer, inner], presets: [])
      ])
      try write("x", shared.appendingPathComponent("inner/model"))
      let keep = Preset(name: "x", transcription: "asr-a", speakers: "inner", summary: "")
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
        Installer(environment: ["HOME": "/h", "SHELL": "/usr/bin/fish"]).profile.path, "/h/.profile"
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
        ["NOTICE", "mlx.metallib", "tmsm", "x.bundle"])
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
      try write("tmsm", installer.programFolder.appendingPathComponent("tmsm"))
      let release = dir.appendingPathComponent("release")
      try write("tmsm", release.appendingPathComponent("tmsm"))
      expectError(t, SetupError.foreignFiles(installer.programFolder.path, ["diary.txt"])) {
        try installer.installProgram(from: release)
      }
      t.expect(read(installer.programFolder.appendingPathComponent("diary.txt")), "mine")
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
      try write("w", home.models(engine: "x").appendingPathComponent("m"))
      try write("c", caches.appendingPathComponent("e5"))
      try write("keep", other)
      try write("export A=1\n", userHome.appendingPathComponent(".zprofile"))
      try write("tmsm", installer.executable)
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
      let uninstaller = Uninstaller(home: home, installer: installer, leftovers: [])
      t.expect(uninstaller.run([.home(home.root)]).count, 0)
      t.expect(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

      try write("{}", home.configFile)
      try write("x", support.appendingPathComponent("Other App/data"))
      t.expect(uninstaller.run([.home(home.root)]).count, 0)
      t.expect(read(support.appendingPathComponent("Other App/data")), "x")

      let custom = TMSMHome(root: dir.appendingPathComponent("a/b/tmsm"))
      try write("{}", custom.configFile)
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
      let installer = Installer(environment: ["HOME": dir.path])
      try write("tmsm", installer.executable)
      let uninstaller = Uninstaller(
        home: TMSMHome(root: shared), installer: installer, leftovers: [])
      let errors = uninstaller.run(uninstaller.plan().filter { $0 != .keychain })
      t.expect(
        errors.map { ($0 as? SetupError) },
        [SetupError.foreignFiles(shared.path, ["thesis.pages"])])
      t.expect(read(shared.appendingPathComponent("thesis.pages")), "mine")
      t.expect(exists(installer.programFolder), false, "the program still goes")
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
        // Only lines about tmsm: `xcode-select --install` is not ours to check.
        let ours = text.components(separatedBy: "\n").filter { $0.contains("tmsm") }
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
