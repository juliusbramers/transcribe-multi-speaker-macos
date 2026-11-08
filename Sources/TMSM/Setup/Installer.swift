import Foundation

/// Where the program lives and how it gets on PATH.
///
/// - Program: `~/.tmsm/` holds the `tmsm` executable and the files it needs beside it (Metal
///   library, bundled dylibs, resource bundles, NOTICE, uninstall.sh), plus a manifest,
///   `.tmsm-program`, that lists them. Nothing else ever goes there, and a folder without the
///   manifest is never replaced or removed.
/// - PATH: one line, marked `# tmsm`, in the login file of the user's shell (zsh `.zprofile`;
///   bash the first of `.bash_profile`, `.bash_login`, `.profile`; others `.profile`), or for
///   fish an owned snippet in `conf.d`. The manifest records which file and which folders the
///   install created, for uninstall.
///
/// `$HOME` is honoured throughout, so a temp-HOME test installs and uninstalls inside it.
public struct Installer {
  public static let folderName = ".tmsm"
  public static let marker = "# tmsm"
  public static let pathLine = "export PATH=\"$HOME/.tmsm:$PATH\" \(marker)"
  public static let manifestName = ".tmsm-program"
  public static let fishSnippet = """
    \(marker): added by `tmsm install`, removed by `tmsm uninstall`.
    if not contains -- $HOME/.tmsm $PATH
        set -gx PATH $HOME/.tmsm $PATH
    end

    """

  public var userHome: URL
  public var shell: String
  public var configHome: URL

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    userHome =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    shell = environment["SHELL"] ?? "/bin/zsh"
    configHome =
      environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? userHome.appendingPathComponent(".config", isDirectory: true)
  }

  public var programFolder: URL { userHome.appendingPathComponent(Installer.folderName) }
  public var executable: URL { programFolder.appendingPathComponent("tmsm") }
  public var manifest: URL { programFolder.appendingPathComponent(Installer.manifestName) }
  /// Leftovers of an interrupted install or update.
  var stagingFolders: [URL] {
    [".tmsm.new", ".tmsm.old"].map { userHome.appendingPathComponent($0) }
  }

  var shellName: String { URL(fileURLWithPath: shell).lastPathComponent }
  public var usesFish: Bool { shellName == "fish" }
  public var fishFile: URL {
    configHome.appendingPathComponent("fish/conf.d/tmsm.fish")
  }

  /// The login file that gets the PATH line (for fish: the conf.d snippet).
  public var profile: URL {
    let file = { (name: String) in self.userHome.appendingPathComponent(name) }
    switch shellName {
    case "zsh":
      return file(".zprofile")
    case "bash":
      // Bash reads only the first of these that exists; adding an earlier one would hide the rest.
      let candidates = [".bash_profile", ".bash_login", ".profile"].map(file)
      return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    case "fish":
      return fishFile
    default:
      return file(".profile")
    }
  }

  /// Every login file uninstall sweeps for marked lines, whichever shell was used.
  public var profiles: [URL] {
    [".zprofile", ".bash_profile", ".bash_login", ".profile"].map {
      userHome.appendingPathComponent($0)
    }
  }

  // MARK: Program files

  /// What belongs to the program in a release folder; anything else is left out of the copy.
  public static func isProgramItem(_ name: String) -> Bool {
    ["tmsm", "NOTICE", "README.md", "LICENSE", "uninstall.sh"].contains(name)
      || name.hasSuffix(".metallib") || name.hasSuffix(".dylib") || name.hasSuffix(".bundle")
      || name.hasSuffix(".resources")
  }

  /// The program items in `folder`; throws if there is no `tmsm` executable in it.
  public static func programItems(in folder: URL) throws -> [String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    guard names.contains("tmsm") else { throw SetupError.notAProgramFolder(folder.path) }
    return names.filter(isProgramItem).sorted()
  }

  /// Copies the program from `source` (the folder the running `tmsm` is in) into the program
  /// folder. A new copy is staged first, with its manifest written before anything else, and
  /// swapped in, so a failed copy leaves the old one. Returns false when `source` already is
  /// the program folder.
  @discardableResult
  public func installProgram(from source: URL) throws -> Bool {
    let fm = FileManager.default
    let from = source.resolvingSymlinksInPath().standardizedFileURL
    if from.path == programFolder.resolvingSymlinksInPath().standardizedFileURL.path {
      return false
    }
    let items = try Installer.programItems(in: from)
    // Only ever replace our own folders: check all three before anything moves.
    try checkOwned(programFolder, allowLegacy: true)
    for folder in stagingFolders { try checkOwned(folder, allowLegacy: false) }
    let staging = stagingFolders[0]
    let old = stagingFolders[1]
    for leftover in stagingFolders { try removeProgramFolder(leftover) }
    var manifest = (try? Manifest.read(programFolder)) ?? Manifest()
    manifest.items = items
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    try manifest.write(staging)
    for name in items {
      try fm.copyItem(
        at: from.appendingPathComponent(name), to: staging.appendingPathComponent(name))
    }
    if fm.fileExists(atPath: programFolder.path) {
      if (try? Manifest.read(programFolder)) == nil {  // a legacy folder: claim it first
        try Manifest(items: try Installer.programItems(in: programFolder)).write(programFolder)
      }
      try fm.moveItem(at: programFolder, to: old)
    }
    try fm.moveItem(at: staging, to: programFolder)
    try removeProgramFolder(old)
    return true
  }

  /// Removes a program folder, but only if its manifest covers everything in it.
  func removeProgramFolder(_ folder: URL) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    try checkOwned(folder, allowLegacy: folder.path == programFolder.path)
    try FileManager.default.removeItem(at: folder)
  }

  /// Throws unless `folder` (if it exists) is ours: its manifest lists everything in it. A
  /// legacy `~/.tmsm` from before manifests passes only if it holds an executable `tmsm`, our
  /// NOTICE, and nothing outside the program items.
  func checkOwned(_ folder: URL, allowLegacy: Bool) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder.path) else { return }
    let names = try fm.contentsOfDirectory(atPath: folder.path)
      .filter { $0 != ".DS_Store" && $0 != Installer.manifestName }
    if let manifest = try? Manifest.read(folder) {
      let foreign = names.filter { !manifest.items.contains($0) }.sorted()
      guard foreign.isEmpty else { throw SetupError.foreignFiles(folder.path, foreign) }
      return
    }
    let notice = try? String(
      contentsOf: folder.appendingPathComponent("NOTICE"), encoding: .utf8)
    guard allowLegacy, names.allSatisfy(Installer.isProgramItem),
      fm.isExecutableFile(atPath: folder.appendingPathComponent("tmsm").path),
      notice?.hasPrefix("tmsm — transcribe multi-speaker") == true
    else { throw SetupError.notOwned(folder.path) }
  }

  /// `.tmsm-program`: the items of a program folder, and what the install changed outside it.
  struct Manifest: Equatable {
    var items: [String] = []
    /// The login file that holds the PATH line (or the fish snippet).
    var profile: String?
    /// Folders the install created for the PATH setup (fish's conf.d and parents).
    var created: [String] = []

    static func read(_ folder: URL) throws -> Manifest {
      let text = try String(
        contentsOf: folder.appendingPathComponent(Installer.manifestName), encoding: .utf8)
      var manifest = Manifest()
      for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "item": manifest.items.append(parts[1])
        case "profile": manifest.profile = parts[1]
        case "created": manifest.created.append(parts[1])
        default: continue
        }
      }
      return manifest
    }

    func write(_ folder: URL) throws {
      var lines = ["# tmsm program folder. `tmsm uninstall` removes it and what is listed here."]
      lines += items.map { "item \($0)" }
      if let profile { lines.append("profile \(profile)") }
      lines += created.map { "created \($0)" }
      try (lines.joined(separator: "\n") + "\n").write(
        to: folder.appendingPathComponent(Installer.manifestName), atomically: true,
        encoding: .utf8)
    }
  }

  // MARK: PATH

  /// Makes the shell's own login file hold the one marked line (fish: the snippet), and no
  /// other file hold one, so after a change of shell the line moves. Returns true when
  /// anything was written. Records the file in the manifest when there is one.
  @discardableResult
  public func addPathLine() throws -> Bool {
    var changed = false
    for other in profiles where other.path != profile.path {
      if try removeMarkedLines(from: other) { changed = true }
    }
    var created: [String] = []
    if usesFish {
      if (try? String(contentsOf: fishFile, encoding: .utf8)) != Installer.fishSnippet {
        guard !FileManager.default.fileExists(atPath: fishFile.path) else {
          throw SetupError.foreignFiles(fishFile.path, [fishFile.lastPathComponent])
        }
        created = try createParents(of: fishFile)
        try Installer.fishSnippet.write(to: fishFile, atomically: true, encoding: .utf8)
        changed = true
      }
    } else {
      if try removeFishSnippet() { changed = true }
      var lines = try Installer.lines(of: profile) ?? []
      if lines.filter(Installer.isMarkedLine) != [Installer.pathLine] {
        lines = lines.filter { !Installer.isMarkedLine($0) } + [Installer.pathLine]
        try Installer.write(lines, to: profile)
        changed = true
      }
    }
    if var manifest = try? Manifest.read(programFolder) {
      manifest.profile = profile.path
      manifest.created = Array(Set(manifest.created + created)).sorted()
      try manifest.write(programFolder)
    }
    return changed
  }

  /// Removes every marked line and the fish snippet. A login file that held nothing else is
  /// removed with it (unless it is a symlink). Returns the files that changed.
  @discardableResult
  public func removePathLines() throws -> [URL] {
    var changed = try profiles.filter { try removeMarkedLines(from: $0) }
    if try removeFishSnippet() { changed.append(fishFile) }
    return changed
  }

  /// Removes the fish snippet only if it is exactly ours, then the folders the install made
  /// for it, while they are empty.
  private func removeFishSnippet() throws -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fishFile.path) else { return false }
    guard (try? String(contentsOf: fishFile, encoding: .utf8)) == Installer.fishSnippet else {
      throw SetupError.foreignFiles(fishFile.path, [fishFile.lastPathComponent])
    }
    try fm.removeItem(at: fishFile)
    let created = (try? Manifest.read(programFolder))?.created ?? []
    for dir in created.sorted(by: { $0.count > $1.count }) {
      let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? ["?"]
      if names.filter({ $0 != ".DS_Store" }).isEmpty { try? fm.removeItem(atPath: dir) }
    }
    return true
  }

  /// Creates the missing parents of `file`; returns the ones it created, deepest last.
  private func createParents(of file: URL) throws -> [String] {
    var missing: [URL] = []
    var dir = file.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
      missing.insert(dir, at: 0)
      dir = dir.deletingLastPathComponent()
    }
    for folder in missing {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    return missing.map(\.path)
  }

  private func removeMarkedLines(from profile: URL) throws -> Bool {
    guard let lines = try Installer.lines(of: profile) else { return false }
    let kept = lines.filter { !Installer.isMarkedLine($0) }
    guard kept.count != lines.count else { return false }
    let isLink = (try? profile.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
    if kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) && isLink != true {
      try FileManager.default.removeItem(at: profile)
    } else {
      try Installer.write(kept, to: profile)
    }
    return true
  }

  /// Writes through a symlinked profile (dotfile managers) instead of replacing the link, and
  /// keeps the file's permissions.
  static func write(_ lines: [String], to file: URL) throws {
    let target = file.resolvingSymlinksInPath()
    let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try text.write(to: target, atomically: true, encoding: .utf8)
    if let mode {
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }
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
