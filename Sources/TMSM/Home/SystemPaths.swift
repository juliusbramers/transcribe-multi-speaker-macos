import Foundation

/// Paths outside `TMSM_HOME` that macOS creates for the `tmsm` process and that tmsm can't
/// redirect through a supported API:
///
/// - `~/Library/Caches/tmsm`: Core ML's compiled-model cache (`com.apple.e5rt.e5bundlecache`),
///   managed by the system.
/// - `~/Library/HTTPStorages/tmsm`: the URLSession cookie/HSTS store. FluidAudio's downloads use
///   its own default-configuration session and expose no public way to swap it.
///
/// These and the output file are the only things a run writes outside `TMSM_HOME`.
/// `tmsm uninstall` removes them; the temp-HOME scan checks them.
public enum SystemPaths {
  public static let processName = "tmsm"

  public static func leftovers(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    let home =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent("Library/Caches/\(processName)", isDirectory: true),
      home.appendingPathComponent("Library/HTTPStorages/\(processName)", isDirectory: true),
    ]
  }
}
