import Foundation

/// Where the program lives and how it gets on PATH.
///
/// - Program: `~/.tmsm/` holds the `tmsm` executable and the files it needs beside it (Metal
///   library, resource bundles, NOTICE). Nothing else ever goes there.
/// - PATH: one line, marked `# tmsm`, in the login profile of the user's shell.
///
/// `$HOME` is honoured throughout, so a temp-HOME test installs and uninstalls inside it.
public struct Installer {
  public static let folderName = ".tmsm"
  public static let marker = "# tmsm"
  public static let pathLine = "export PATH=\"$HOME/.tmsm:$PATH\" \(marker)"

  public var userHome: URL
  public var shell: String

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    userHome =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    shell = environment["SHELL"] ?? "/bin/zsh"
  }

  public var programFolder: URL { userHome.appendingPathComponent(Installer.folderName) }
  public var executable: URL { programFolder.appendingPathComponent("tmsm") }
  /// Leftovers of an interrupted install or update.
  var stagingFolders: [URL] {
    [".tmsm.new", ".tmsm.old"].map { userHome.appendingPathComponent($0) }
  }

  /// The profile that gets the PATH line: the login profile of the user's shell.
  public var profile: URL {
    let name: String
    switch URL(fileURLWithPath: shell).lastPathComponent {
    case "zsh": name = ".zprofile"
    case "bash": name = ".bash_profile"
    default: name = ".profile"
    }
    return userHome.appendingPathComponent(name)
  }

  /// Every profile uninstall cleans, whichever shell was used at install time.
  public var profiles: [URL] {
    [".zprofile", ".bash_profile", ".profile"].map { userHome.appendingPathComponent($0) }
  }

  // MARK: Program files

  /// What belongs to the program in a release folder; anything else is left out of the copy.
  public static func isProgramItem(_ name: String) -> Bool {
    ["tmsm", "NOTICE", "README.md", "LICENSE"].contains(name)
      || name.hasSuffix(".metallib") || name.hasSuffix(".bundle") || name.hasSuffix(".resources")
  }

  /// The program items in `folder`; throws if there is no `tmsm` executable in it.
  public static func programItems(in folder: URL) throws -> [String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    guard names.contains("tmsm") else { throw SetupError.notAProgramFolder(folder.path) }
    return names.filter(isProgramItem).sorted()
  }

  /// Copies the program from `source` (the folder the running `tmsm` is in) into the program
  /// folder. A new copy is staged first and swapped in, so a failed copy leaves the old one.
  /// Returns false when `source` already is the program folder.
  @discardableResult
  public func installProgram(from source: URL) throws -> Bool {
    let fm = FileManager.default
    let from = source.resolvingSymlinksInPath().standardizedFileURL
    if from.path == programFolder.resolvingSymlinksInPath().standardizedFileURL.path {
      return false
    }
    let items = try Installer.programItems(in: from)
    // Only ever replace our own folder: check before anything moves.
    try Installer.checkOwned(programFolder)
    let staging = stagingFolders[0]
    let old = stagingFolders[1]
    for leftover in stagingFolders { try removeProgramFolder(leftover) }
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    for name in items {
      try fm.copyItem(
        at: from.appendingPathComponent(name), to: staging.appendingPathComponent(name))
    }
    if fm.fileExists(atPath: programFolder.path) {
      try fm.moveItem(at: programFolder, to: old)
    }
    try fm.moveItem(at: staging, to: programFolder)
    try removeProgramFolder(old)
    return true
  }

  /// Removes a program folder, but only if everything in it is ours.
  func removeProgramFolder(_ folder: URL) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    try Installer.checkOwned(folder)
    try FileManager.default.removeItem(at: folder)
  }

  /// Throws unless everything in `folder` (if it exists) is a program item.
  static func checkOwned(_ folder: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder.path) else { return }
    let names = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
    let foreign = names.filter { !Installer.isProgramItem($0) }.sorted()
    guard foreign.isEmpty else { throw SetupError.foreignFiles(folder.path, foreign) }
  }

  // MARK: PATH

  /// Adds the marked line unless one is there. Returns true when it wrote one.
  @discardableResult
  public func addPathLine() throws -> Bool {
    if profiles.contains(where: {
      (try? Installer.lines(of: $0))?.contains(Installer.pathLine) == true
    }) {
      return false
    }
    var text = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += Installer.pathLine + "\n"
    try text.write(to: profile, atomically: true, encoding: .utf8)
    return true
  }

  /// Removes every marked line. A profile that held nothing else is removed with it.
  /// Returns the profiles that changed.
  @discardableResult
  public func removePathLines() throws -> [URL] {
    var changed: [URL] = []
    for profile in profiles {
      guard let lines = try Installer.lines(of: profile) else { continue }
      let kept = lines.filter { !Installer.isMarkedLine($0) }
      guard kept.count != lines.count else { continue }
      if kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        try FileManager.default.removeItem(at: profile)
      } else {
        try (kept.joined(separator: "\n") + "\n").write(
          to: profile, atomically: true, encoding: .utf8)
      }
      changed.append(profile)
    }
    return changed
  }

  /// Ours: ends with the marker and names the program folder.
  static func isMarkedLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasSuffix(marker) && trimmed.contains("/\(folderName):")
  }

  static func lines(of file: URL) throws -> [String]? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    var lines = try String(contentsOf: file, encoding: .utf8)
      .components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// The program folder is on this process's PATH.
  public func isOnPath(_ environment: [String: String]) -> Bool {
    (environment["PATH"] ?? "").split(separator: ":").contains { $0 == programFolder.path }
  }
}
