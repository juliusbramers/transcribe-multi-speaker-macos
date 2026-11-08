import Foundation

/// `config.json` in the tmsm home. Written by `tmsm setup`; a run only reads it.
public struct Config: Codable, Sendable, Equatable {
  /// Not a catalogue preset: the two models below, picked one by one.
  public static let individual = "individual"

  /// The preset used when `--preset` is not given.
  public var preset: String?
  /// The models of `individual`.
  public var transcription: String?
  public var speakers: String?

  public init(preset: String? = nil, transcription: String? = nil, speakers: String? = nil) {
    self.preset = preset
    self.transcription = transcription
    self.speakers = speakers
  }

  /// A missing file means "no choice yet": runs fall back to the default preset, silently.
  public static func load(from url: URL) throws -> Config {
    guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(Config.self, from: data)
    } catch {
      throw TMSMError.invalidConfig(url.path, error.localizedDescription)
    }
  }

  public func save(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  /// The preset a run uses: `name` (from `--preset`), else the configured one, else `default`.
  /// `individual` becomes a preset made of the two configured models.
  public func resolvePreset(_ name: String?, catalogue: Catalogue) throws -> Preset {
    let chosen = (name ?? preset ?? Catalogue.defaultPreset).lowercased()
    guard chosen == Config.individual else { return try catalogue.preset(named: chosen) }
    guard let transcription, let speakers else { throw SetupError.noIndividualModels }
    guard try catalogue.entry(transcription).kind == .transcription else {
      throw SetupError.wrongKind(transcription, .transcription)
    }
    guard try catalogue.entry(speakers).kind == .speakers else {
      throw SetupError.wrongKind(speakers, .speakers)
    }
    return Preset(
      name: Config.individual, transcription: transcription, speakers: speakers,
      summary: "\(transcription) + \(speakers)")
  }
}
