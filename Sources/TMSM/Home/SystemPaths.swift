import Darwin
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

  /// Resolved against the account's home directory, not `$HOME`: macOS creates these folders
  /// there even when `$HOME` points elsewhere (checked with a temp-HOME run, 2026-11-08).
  public static func leftovers(accountHome: URL = SystemPaths.accountHome) -> [URL] {
    [
      accountHome.appendingPathComponent("Library/Caches/\(processName)", isDirectory: true),
      accountHome.appendingPathComponent("Library/HTTPStorages/\(processName)", isDirectory: true),
    ]
  }

  /// The home directory from the user database, which ignores `$HOME`.
  public static var accountHome: URL {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
}
