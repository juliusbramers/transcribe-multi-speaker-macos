import Darwin
import FluidAudio
import Foundation
import Synchronization

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
  /// - `TMPDIR` → a folder of this run's own under `cache/tmp` (FluidAudio's partial downloads
  ///   and disk-backed audio use the temp folder), so parallel runs never share one
  /// - `HF_HOME` / `HF_HUB_CACHE` for Hugging Face clients
  /// - the shared `URLCache` (download sessions use the default configuration)
  ///
  /// Returns this run's temp folder; pass it to `removeRunTemporary(_:)` at the end.
  @discardableResult
  public func activate(runID: String = UUID().uuidString) throws -> URL {
    let fm = FileManager.default
    let runTemp = temporary.appendingPathComponent("run-\(runID)", isDirectory: true)
    for dir in [models, runTemp, urlCache, huggingFace] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try TMSMHome.lock(runTemp)
    setenv("TMPDIR", runTemp.path + "/", 1)
    setenv("HF_HOME", huggingFace.path, 1)
    setenv("HF_HUB_CACHE", huggingFace.appendingPathComponent("hub").path, 1)
    URLCache.shared = URLCache(
      memoryCapacity: 4 << 20, diskCapacity: 0, directory: urlCache)
    // stderr belongs to our progress line; FluidAudio's own errors still reach us as throws.
    AppLogger.mirrorsToConsole = false
    AppLogger.minimumLevel = .error
    removeStaleTemporary()
    return runTemp
  }

  /// Removes this run's temp folder, and nothing else.
  public func removeRunTemporary(_ runTemp: URL) {
    guard runTemp.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL
    else { return }
    try? FileManager.default.removeItem(at: runTemp)
    TMSMHome.release(runTemp)
  }

  /// Old run folders are removed only if no live run holds their lock: a crashed run's lock goes
  /// with its process. Age alone proves nothing (a slow download leaves the folder's date alone).
  func removeStaleTemporary(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
    let fm = FileManager.default
    let items =
      (try? fm.contentsOfDirectory(
        at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for item in items where item.lastPathComponent.hasPrefix("run-") {
      let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      guard let modified, now.timeIntervalSince(modified) > age else { continue }
      let fd = open(item.appendingPathComponent(TMSMHome.lockName).path, O_RDONLY)
      if fd >= 0 {
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }  // a live run holds it
      }
      try? fm.removeItem(at: item)
    }
  }

  // MARK: Run locks

  static let lockName = ".lock"
  private static let held = Mutex<[String: Int32]>([:])

  /// Takes an exclusive advisory lock on the run folder, held until `release` or process exit.
  static func lock(_ runTemp: URL) throws {
    let path = runTemp.appendingPathComponent(lockName).path
    let fd = open(path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if fd >= 0 { close(fd) }
      throw TMSMError.outputFailed(path, "can't lock this run's temp folder")
    }
    held.withLock { $0[runTemp.standardizedFileURL.path] = fd }
  }

  static func release(_ runTemp: URL) {
    let fd = held.withLock { $0.removeValue(forKey: runTemp.standardizedFileURL.path) }
    if let fd { close(fd) }
  }
}
