import Foundation

/// `config.json` in the tmsm home. Written by `tmsm setup` (session C); a run only reads it.
public struct Config: Codable, Sendable, Equatable {
  /// The preset used when `--preset` is not given.
  public var preset: String?

  public init(preset: String? = nil) {
    self.preset = preset
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
}
