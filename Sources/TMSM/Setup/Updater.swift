import Foundation

/// `tmsm update`: the same steps as the install line. Find the latest release, download the
/// tarball and SHA256SUMS, check the hash, unpack, and let the new `tmsm` install itself.
/// Uses the system's curl, shasum and tar, so nothing is cached outside a temp folder.
public struct Updater {
  public static let repository = "juliusbramers/transcribe-multi-speaker-macos"

  /// Where release assets live. `TMSM_RELEASES` overrides it (a `file://` folder in tests).
  public var releases: String
  public var runner: (String, [String], URL?) throws -> String

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    releases =
      environment["TMSM_RELEASES"] ?? "https://github.com/\(Updater.repository)/releases"
    runner = { tool, arguments, cwd in
      // curl has its own limits (see `curlLimits`); this outer bound only catches a hang.
      try Updater.run(tool, arguments, in: cwd, timeout: tool.hasSuffix("curl") ? 3_700 : 600)
    }
  }

  /// No connection in 20 s, or under 1 KB/s for a minute, or over an hour: give up.
  static let curlLimits = [
    "--connect-timeout", "20", "--speed-limit", "1024", "--speed-time", "60", "--max-time", "3600",
  ]

  public static func assetName(_ version: String) -> String {
    "tmsm-\(version)-macos-arm64.tar.gz"
  }

  /// The version of the release `releases/latest` redirects to.
  public func latestVersion() throws -> String {
    let url = try runner(
      "/usr/bin/curl",
      ["-fsSLI"] + Updater.curlLimits
        + ["-o", "/dev/null", "-w", "%{url_effective}", "\(releases)/latest"], nil)
    guard let version = Updater.version(fromTagURL: url) else {
      throw SetupError.download("can't tell the latest version from \(url)")
    }
    return version
  }

  /// `…/releases/tag/v1.2.3` → `1.2.3`.
  public static func version(fromTagURL url: String) -> String? {
    let last = url.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last
    guard let last, last.hasPrefix("v") else { return nil }
    let version = String(last.dropFirst())
    return parse(version) == nil ? nil : version
  }

  static func parse(_ version: String) -> [Int]? {
    let parts = version.split(separator: ".").map { Int($0) }
    guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.compactMap { $0 }
  }

  /// True when `candidate` is a later version than `current`.
  public static func isNewer(_ candidate: String, than current: String) -> Bool {
    guard let a = parse(candidate), let b = parse(current) else { return false }
    return b.lexicographicallyPrecedes(a)
  }

  /// Downloads and checks release `version` into `folder`, unpacks it, and returns the
  /// unpacked program folder.
  public func fetch(_ version: String, into folder: URL) throws -> URL {
    let asset = Updater.assetName(version)
    let base = "\(releases)/download/v\(version)"
    for name in [asset, "SHA256SUMS"] {
      _ = try runner(
        "/usr/bin/curl", ["-fsSL"] + Updater.curlLimits + ["-o", name, "\(base)/\(name)"], folder)
    }
    let sums = try String(
      contentsOf: folder.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
    guard let line = sums.split(separator: "\n").first(where: { $0.hasSuffix(" \(asset)") }) else {
      throw SetupError.checksum(asset)
    }
    let check = folder.appendingPathComponent("check.sha256")
    try (line + "\n").write(to: check, atomically: true, encoding: .utf8)
    do {
      _ = try runner("/usr/bin/shasum", ["-a", "256", "-c", "check.sha256"], folder)
    } catch {
      throw SetupError.checksum(asset)
    }
    _ = try runner("/usr/bin/tar", ["-xzf", asset], folder)
    return folder.appendingPathComponent("tmsm-\(version)-macos-arm64", isDirectory: true)
  }

  /// Runs a tool and returns its stdout; a non-zero exit throws with its stderr. Both
  /// streams are drained at the same time (a full stderr pipe can't stall the tool), and a tool
  /// still running after `timeout` seconds is stopped.
  public static func run(
    _ tool: String, _ arguments: [String], in cwd: URL?, timeout: TimeInterval = 600
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    final class Buffer: @unchecked Sendable { var data = Data() }
    let output = Buffer()
    let errors = Buffer()
    let drained = DispatchGroup()
    for (pipe, buffer) in [(out, output), (err, errors)] {
      drained.enter()
      DispatchQueue.global().async {
        buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.leave()
      }
    }
    let name = URL(fileURLWithPath: tool).lastPathComponent
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
      _ = drained.wait(timeout: .now() + 5)
      throw SetupError.download("\(name) took longer than \(Int(timeout)) s and was stopped")
    }
    _ = drained.wait(timeout: .now() + 30)
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errors.data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw SetupError.download("\(name) \(arguments.last ?? ""): \(message)")
    }
    return String(decoding: output.data, as: UTF8.self)
  }
}
