import FluidAudio
import Foundation

/// The one root that holds everything tmsm writes, apart from the transcripts themselves:
/// models, config and every engine cache.
///
/// Default: `~/Library/Application Support/tmsm`. `TMSM_HOME` overrides it.
public struct TMSMHome: Sendable, Equatable {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// Resolves the root from the environment, without touching the disk.
  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TMSMHome {
    if let override = environment["TMSM_HOME"], !override.isEmpty {
      let expanded = (override as NSString).expandingTildeInPath
      return TMSMHome(root: URL(fileURLWithPath: expanded, isDirectory: true))
    }
    // $HOME first, so a temp-HOME test keeps everything inside its HOME.
    let userHome =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return TMSMHome(
      root: userHome.appendingPathComponent("Library/Application Support/tmsm", isDirectory: true))
  }

  /// Models, one folder per engine (`models/fluidaudio`, later `models/mlx`).
  public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
  public func models(engine: String) -> URL {
    models.appendingPathComponent(engine, isDirectory: true)
  }
  /// Engine caches that are not models: temp files, URL cache, Hugging Face hub cache.
  public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
  public var temporary: URL { cache.appendingPathComponent("tmp", isDirectory: true) }
  public var urlCache: URL { cache.appendingPathComponent("urlcache", isDirectory: true) }
  public var huggingFace: URL { cache.appendingPathComponent("huggingface", isDirectory: true) }
  public var configFile: URL { root.appendingPathComponent("config.json") }

  /// Points every process-wide cache we know of into the root. Call before any engine runs.
  ///
  /// - `TMPDIR` (FluidAudio's partial downloads and disk-backed audio use the temp folder)
  /// - `HF_HOME` / `HF_HUB_CACHE` for Hugging Face clients
  /// - the shared `URLCache` (download sessions use the default configuration)
  public func activate() throws {
    let fm = FileManager.default
    for dir in [models, temporary, urlCache, huggingFace] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    setenv("TMPDIR", temporary.path + "/", 1)
    setenv("HF_HOME", huggingFace.path, 1)
    setenv("HF_HUB_CACHE", huggingFace.appendingPathComponent("hub").path, 1)
    URLCache.shared = URLCache(
      memoryCapacity: 4 << 20, diskCapacity: 0, directory: urlCache)
    // stderr belongs to our progress line; FluidAudio's own errors still reach us as throws.
    AppLogger.mirrorsToConsole = false
    AppLogger.minimumLevel = .error
  }

  /// Removes what the temp folder still holds from this run.
  public func cleanTemporary() {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
    else { return }
    for item in items { try? fm.removeItem(at: item) }
  }
}
