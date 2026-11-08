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

  /// What a tmsm home may contain. Anything else means TMSM_HOME points somewhere shared.
  static let homeItems: Set<String> = ["models", "cache", "config.json", ".DS_Store"]

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

  /// Removes the home only if all of it is tmsm's.
  func removeHome(_ url: URL) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
    let foreign = names.filter { !Uninstaller.homeItems.contains($0) }
    guard foreign.isEmpty else { throw SetupError.foreignFiles(url.path, foreign.sorted()) }
    try FileManager.default.removeItem(at: url)
  }
}
