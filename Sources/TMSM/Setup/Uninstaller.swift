import Foundation

/// `tmsm uninstall`: the tmsm home, the Keychain item, the PATH line, the program, and the
/// two folders macOS creates for the tmsm process. Nothing else.
public struct Uninstaller {
  public var home: TMSMHome
  public var installer: Installer
  public var leftovers: [URL]

  public init(
    home: TMSMHome, installer: Installer, leftovers: [URL] = SystemPaths.leftovers()
  ) {
    self.home = home
    self.installer = installer
    self.leftovers = leftovers
  }

  /// Written into a home that tmsm created (or the default one). Uninstall removes a home only
  /// when it holds this file: folder names alone don't prove a folder is ours.
  public static let markerName = ".tmsm-home"

  /// What a tmsm home may contain. Anything else means TMSM_HOME points somewhere shared.
  static let homeItems: Set<String> = [
    "models", "cache", "config.json", ".DS_Store", markerName,
  ]

  /// Call before anything writes to the home. Marks it as tmsm's when tmsm creates it, or when
  /// it is the default location. An existing folder named by TMSM_HOME stays unmarked, so
  /// uninstall will not remove it.
  public static func claim(_ home: TMSMHome, environment: [String: String]) throws {
    let fm = FileManager.default
    let marker = home.root.appendingPathComponent(markerName)
    if fm.fileExists(atPath: marker.path) { return }
    var defaults = environment
    defaults["TMSM_HOME"] = nil
    let isDefault = TMSMHome.resolve(environment: defaults).root.path == home.root.path
    let isNew = !fm.fileExists(atPath: home.root.path)
    guard isNew || isDefault else { return }
    try fm.createDirectory(at: home.root, withIntermediateDirectories: true)
    try Data("This folder belongs to tmsm. `tmsm uninstall` removes it.\n".utf8)
      .write(to: marker)
  }

  public enum Item: Sendable, Equatable {
    case home(URL)
    case keychain
    case pathLines
    case program(URL)
    case systemFolder(URL)
  }

  /// What is there to remove, for the confirmation and the report.
  public func plan() -> [Item] {
    let fm = FileManager.default
    var items: [Item] = []
    if fm.fileExists(atPath: home.root.path) { items.append(.home(home.root)) }
    items.append(.keychain)
    items.append(.pathLines)
    for folder in [installer.programFolder] + installer.stagingFolders
    where fm.fileExists(atPath: folder.path) {
      items.append(.program(folder))
    }
    for folder in leftovers where fm.fileExists(atPath: folder.path) {
      items.append(.systemFolder(folder))
    }
    return items
  }

  public static func describe(_ item: Item) -> String {
    switch item {
    case .home(let url): return "models, config and caches: \(url.path)"
    case .keychain: return "the Hugging Face token in the Keychain (service \"tmsm\"), if any"
    case .pathLines: return "the PATH line marked \(Installer.marker)"
    case .program(let url): return "the program: \(url.path)"
    case .systemFolder(let url): return "system cache: \(url.path)"
    }
  }

  /// Removes everything in the plan it may. Errors are collected, not fatal, so one refusal
  /// (say, foreign files in TMSM_HOME) does not leave the rest behind.
  public func run(_ items: [Item]) -> [Error] {
    var errors: [Error] = []
    for item in items {
      do {
        switch item {
        case .home(let url): try removeHome(url)
        case .keychain: try Credentials.removeAll()
        case .pathLines: try installer.removePathLines()
        case .program(let url): try installer.removeProgramFolder(url)
        case .systemFolder(let url): try FileManager.default.removeItem(at: url)
        }
      } catch {
        errors.append(error)
      }
    }
    return errors
  }

  /// Removes the home only if tmsm marked it as its own and nothing else is in it.
  func removeHome(_ url: URL) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
    guard names.contains(Uninstaller.markerName) else {
      throw SetupError.notTMSMHome(url.path)
    }
    let foreign = names.filter { !Uninstaller.homeItems.contains($0) }
    guard foreign.isEmpty else { throw SetupError.foreignFiles(url.path, foreign.sorted()) }
    try FileManager.default.removeItem(at: url)
    removeEmptyDefaultParents(of: url)
  }

  /// When the home was the default `~/Library/Application Support/tmsm` and tmsm created those
  /// parents (a fresh account, or a temp-HOME test), they go too, but only while empty.
  func removeEmptyDefaultParents(of url: URL) {
    let fm = FileManager.default
    let user = installer.userHome.standardizedFileURL
    let library = user.appendingPathComponent("Library", isDirectory: true)
    let support = library.appendingPathComponent("Application Support", isDirectory: true)
    guard url.deletingLastPathComponent().standardizedFileURL.path == support.path else { return }
    for folder in [support, library] {
      let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
      guard names.filter({ $0 != ".DS_Store" }).isEmpty else { return }
      try? fm.removeItem(at: folder)
    }
  }
}
