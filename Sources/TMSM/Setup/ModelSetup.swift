import Foundation

/// Choosing models, downloading them, and removing the ones no longer needed. Used by the
/// first-launch wizard and `tmsm setup`. Every name, size and summary it shows comes from the
/// catalogue, so the wizard, `tmsm setup --list` and the docs never drift from the code.
public struct ModelSetup: Sendable {
  public var home: TMSMHome
  public var catalogue: Catalogue
  public var environment: [String: String]

  public init(
    home: TMSMHome, catalogue: Catalogue = .shared,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.catalogue = catalogue
    self.environment = environment
  }

  // MARK: What there is

  /// Presets plus `individual`, in catalogue order.
  public var choices: [String] { catalogue.presetNames + [Config.individual] }

  /// Every catalogue entry a preset may run (routes, language detectors, speakers): what
  /// "delete unused models" keeps, including fallbacks a run fetched on its own.
  public static func modelIDs(_ preset: Preset) -> [String] { preset.entries }

  /// What setup downloads for a preset (see `Preset.setupEntries`).
  public func setupIDs(_ preset: Preset) -> [String] { preset.setupEntries(in: catalogue) }

  /// Models a run may still fetch in a language setup didn't prepare for.
  public func laterIDs(_ preset: Preset) -> [String] {
    let now = setupIDs(preset)
    return Self.modelIDs(preset).filter { !now.contains($0) }
  }

  func megabytes(_ ids: [String]) -> Int {
    ids.compactMap { try? catalogue.entry($0).downloadMB }.reduce(0, +)
  }

  /// The setup download.
  public func downloadMB(_ preset: Preset) -> Int { megabytes(setupIDs(preset)) }

  /// The one place that describes a preset's footprint: its measured peak RAM, else the
  /// summary alone.
  public static func memoryText(_ preset: Preset) -> String {
    guard let ram = preset.ramGB else { return preset.summary }
    let gb = { (v: Double) in String(format: v < 10 ? "%.1f" : "%.0f", v) }
    let range =
      ram.lowerBound == ram.upperBound
      ? gb(ram.upperBound) : "\(gb(ram.lowerBound))–\(gb(ram.upperBound))"
    return "\(preset.summary); peak RAM \(range) GB"
  }

  /// The table `tmsm setup --list` prints and the docs quote verbatim. `*` marks the preset
  /// runs use: the configured one, else `default`.
  public func listing(current: Config) -> String {
    var lines = ["Presets (tmsm setup --preset <name>):"]
    let inUse = current.preset ?? Catalogue.defaultPreset
    let width = choices.map(\.count).max() ?? 0
    for preset in catalogue.presets {
      let mark = inUse == preset.name ? "*" : " "
      lines.append("\(mark) \(pad(preset.name, width))  \(Self.memoryText(preset))")
      lines.append(
        "  \(pad("", width))  \(Self.size(downloadMB(preset))) download: "
          + setupIDs(preset).joined(separator: ", "))
      let later = laterIDs(preset)
      if !later.isEmpty {
        lines.append(
          "  \(pad("", width))  other languages may add \(Self.size(megabytes(later))): "
            + later.joined(separator: ", "))
      }
    }
    let mark = inUse == Config.individual ? "*" : " "
    lines.append(
      "\(mark) \(pad(Config.individual, width))  any two models below "
        + "(tmsm setup --transcription <id> --speakers <id>)")
    for kind in [CatalogueEntry.Kind.transcription, .speakers] {
      lines.append("")
      lines.append(kind == .transcription ? "Speech-to-text models:" : "Speaker models:")
      let entries = catalogue.entries.filter { Self.offered($0, as: kind) }
      let idWidth = entries.map(\.id.count).max() ?? 0
      for entry in entries {
        lines.append("  \(pad(entry.id, idWidth))  \(describe(entry))")
      }
    }
    lines.append("")
    lines.append("* = in use")
    return lines.joined(separator: "\n")
  }

  /// Joint models (words and speakers from one model) are offered among the speech-to-text
  /// models; with one of them the speaker model is not run.
  static func offered(_ entry: CatalogueEntry, as kind: CatalogueEntry.Kind) -> Bool {
    entry.kind == kind || (kind == .transcription && entry.kind == .joint)
  }

  func describe(_ entry: CatalogueEntry) -> String {
    var parts = [entry.name, Self.size(entry.downloadMB)]
    if entry.kind == .joint { parts.append("labels speakers itself") }
    if !entry.languages.isEmpty { parts.append("\(entry.languages.count) languages") }
    parts.append(entry.license)
    if entry.gated { parts.append("gated: needs a Hugging Face token") }
    return parts.joined(separator: ", ")
  }

  static func size(_ mb: Int) -> String {
    mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB"
  }

  private func pad(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
  }

  // MARK: Choosing

  /// The config for non-interactive flags. `--transcription`/`--speakers` imply `individual`;
  /// a missing half is taken from the current setting.
  public func config(
    preset: String?, transcription: String?, speakers: String?, current: Config
  ) throws -> Config {
    if transcription != nil || speakers != nil {
      if let preset, preset.lowercased() != Config.individual {
        throw SetupError.needsTerminal(
          "--transcription and --speakers go with --preset individual (or no --preset).")
      }
      let base = try current.resolvePreset(nil, catalogue: catalogue)
      let config = Config(
        preset: Config.individual, transcription: transcription ?? base.transcription,
        speakers: speakers ?? base.speakers)
      _ = try config.resolvePreset(nil, catalogue: catalogue)
      return config
    }
    guard let preset else {
      throw SetupError.needsTerminal("Pass --preset, or --transcription and --speakers.")
    }
    let name = preset.lowercased()
    if name == Config.individual {
      _ = try current.resolvePreset(Config.individual, catalogue: catalogue)
      return Config(
        preset: name, transcription: current.transcription, speakers: current.speakers)
    }
    _ = try catalogue.preset(named: name)
    return Config(preset: name)
  }

  /// The questions: a preset, and for `individual` one model of each kind.
  public func ask(_ console: Console, current: Config) throws -> Config {
    console.say("Choose the transcription quality. You can change it later with `tmsm setup`.")
    let names = choices
    let currentName = current.preset ?? Catalogue.defaultPreset
    for (i, name) in names.enumerated() {
      if let preset = try? catalogue.preset(named: name) {
        console.say(
          "  \(i + 1)) \(name): \(Self.memoryText(preset)), "
            + "\(Self.size(downloadMB(preset))) download")
      } else {
        console.say("  \(i + 1)) \(name): pick the speech-to-text and speaker models yourself")
      }
    }
    let defaultIndex = names.firstIndex(of: currentName) ?? 0
    guard let picked = console.choose("Preset", count: names.count, defaultIndex: defaultIndex)
    else { throw SetupError.cancelled }
    guard names[picked] == Config.individual else { return Config(preset: names[picked]) }

    let base = (try? current.resolvePreset(nil, catalogue: catalogue))
    var chosen: [CatalogueEntry.Kind: String] = [:]
    for kind in [CatalogueEntry.Kind.transcription, .speakers] {
      let entries = catalogue.entries.filter { Self.offered($0, as: kind) }
      console.say(kind == .transcription ? "Speech-to-text model:" : "Speaker model:")
      for (i, entry) in entries.enumerated() {
        console.say("  \(i + 1)) \(entry.id): \(describe(entry))")
      }
      let wanted = kind == .transcription ? base?.transcription : base?.speakers
      let start = entries.firstIndex { $0.id == wanted } ?? 0
      guard let n = console.choose("Model", count: entries.count, defaultIndex: start) else {
        throw SetupError.cancelled
      }
      chosen[kind] = entries[n].id
    }
    return Config(
      preset: Config.individual, transcription: chosen[.transcription],
      speakers: chosen[.speakers])
  }

  /// For gated models: a token from HF_TOKEN, the Keychain, or typed in (hidden) and stored.
  public func ensureToken(for preset: Preset, console: Console) throws {
    let gated = try Self.modelIDs(preset).map(catalogue.entry).filter(\.gated)
    guard let first = gated.first,
      try Credentials.token(environment: environment, attended: console.isInteractive) == nil
    else { return }
    guard console.isInteractive else { throw SetupError.tokenMissing(first.name) }
    console.say(
      "\(first.name) is gated on Hugging Face. Accept its terms on huggingface.co, then paste "
        + "an access token (read access is enough). It is stored in your Keychain.")
    while true {
      guard
        let token = console.askHidden("Hugging Face token: ")?
          .trimmingCharacters(in: .whitespaces), !token.isEmpty
      else { throw SetupError.cancelled }
      if Credentials.looksValid(token) {
        try Credentials.store(token)
        return
      }
      console.say("That does not look like a token (they start with hf_). Try again.")
    }
  }

  // MARK: Downloading

  /// Downloads what the preset needs for English and German, each entry through its engine's
  /// own `prepare` (download bars on stderr). Other languages fetch their model on first use.
  public func prepare(_ preset: Preset, progress: Progress) async throws {
    for id in setupIDs(preset) {
      try await catalogue.entry(id).prepare(home, progress)
    }
  }

  // MARK: Cleaning up

  public struct StoredModel: Sendable, Equatable {
    public var id: String
    public var paths: [URL]
    public var bytes: Int64
  }

  /// Folders earlier tmsm versions downloaded to, which no entry uses any more.
  public static func legacyFolders(_ home: TMSMHome) -> [(id: String, url: URL)] {
    // Nemotron-3 before it was pinned to one commit (now models/fluidaudio/nemotron-<rev>/).
    [
      (
        "nemotron-3 (old download)",
        home.models(engine: "fluidaudio")
          .appendingPathComponent("nemotron-3-diarization")
      )
    ]
  }

  /// Models on disk that `keep` does not use, and old downloads. A path that holds or sits
  /// inside a kept model's path is never offered.
  public func unusedModels(keeping keep: Preset) -> [StoredModel] {
    let kept = Self.modelIDs(keep).compactMap { try? catalogue.entry($0) }
      .flatMap { $0.storage(home) }.map(\.standardizedFileURL.path)
    let fm = FileManager.default
    var seen: Set<String> = []
    let candidates =
      catalogue.entries.map { ($0.id, $0.storage(home)) }
      + Self.legacyFolders(home).map { ($0.id, [$0.url]) }
    return candidates.compactMap { id, storage in
      let paths = storage.map(\.standardizedFileURL).filter { url in
        let path = url.path
        guard fm.fileExists(atPath: path), seen.insert(path).inserted else { return false }
        return !kept.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
      }
      guard !paths.isEmpty else { return nil }
      return StoredModel(id: id, paths: paths, bytes: paths.map(Self.bytes).reduce(0, +))
    }
  }

  public func remove(_ models: [StoredModel]) throws {
    for model in models {
      for path in model.paths { try FileManager.default.removeItem(at: path) }
    }
  }

  static func bytes(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard
      let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
    else { return 0 }
    var total: Int64 = 0
    var items = [url]
    while let next = walker.nextObject() as? URL { items.append(next) }
    for item in items {
      let values = try? item.resourceValues(forKeys: Set(keys))
      if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }

  static func size(bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  // MARK: The whole flow

  /// Downloads what `config` needs, saves it, then offers to delete what it no longer needs.
  /// `deleteUnused`: nil asks (in a terminal) and otherwise keeps.
  public func apply(
    _ config: Config, console: Console, progress: Progress, deleteUnused: Bool?
  ) async throws {
    let preset = try config.resolvePreset(nil, catalogue: catalogue)
    try ensureToken(for: preset, console: console)
    if let first = try Self.modelIDs(preset).map(catalogue.entry)
      .first(where: \.gated)
    {
      try Credentials.exportToken(
        for: first.name, environment: environment, attended: console.isInteractive)
    }
    console.say(
      "Downloading \(preset.name) (\(Self.size(downloadMB(preset)))): "
        + setupIDs(preset).joined(separator: ", "))
    do {
      try await prepare(preset, progress: progress)
      progress.finish()
    } catch {
      progress.finish()
      throw error
    }
    try config.save(to: home.configFile)
    console.say("Ready. tmsm now uses \(preset.name).")

    let unused = unusedModels(keeping: preset)
    guard !unused.isEmpty else { return }
    let total = unused.map(\.bytes).reduce(0, +)
    let names = unused.map(\.id).joined(separator: ", ")
    let delete: Bool
    if let deleteUnused {
      delete = deleteUnused
    } else if console.isInteractive {
      delete = console.confirm(
        "Delete models no longer needed (\(names), \(Self.size(bytes: total)))?", default: false)
    } else {
      delete = false
    }
    if delete {
      try remove(unused)
      console.say("Deleted \(names).")
    } else {
      console.say("Kept \(names) (\(Self.size(bytes: total))). `tmsm setup` offers this again.")
    }
  }
}
