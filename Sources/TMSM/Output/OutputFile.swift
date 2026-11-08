import Darwin
import Foundation

/// Where the transcript goes, and writing it without ever overwriting.
public enum OutputFile {
  /// The preferred path:
  /// - no `--output`: `<desktop>/<name>.md`
  /// - `--output` is an existing folder, or ends in `/`: `<folder>/<name>.md`
  /// - otherwise `--output` is the file path (`.md` added when it has no extension)
  public static func target(
    input: URL, output: String?, desktop: URL, cwd: URL,
    isDirectory: (URL) -> Bool = OutputFile.isDirectory
  ) -> URL {
    let name = input.deletingPathExtension().lastPathComponent + ".md"
    guard let output, !output.isEmpty else { return desktop.appendingPathComponent(name) }
    let expanded = (output as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
    if output.hasSuffix("/") || isDirectory(url) { return url.appendingPathComponent(name) }
    return url.pathExtension.isEmpty ? url.appendingPathExtension("md") : url
  }

  /// `memo.md`, then `memo 2.md`, `memo 3.md`, … as Finder names copies.
  public static func candidate(_ target: URL, _ n: Int) -> URL {
    guard n > 1 else { return target }
    let ext = target.pathExtension
    let stem = target.deletingPathExtension().lastPathComponent
    let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    return target.deletingLastPathComponent().appendingPathComponent(name)
  }

  /// Writes `text` to the first free candidate and returns its path. Creation is exclusive
  /// (`O_EXCL`), so a file that appears meanwhile is never replaced.
  public static func write(_ text: String, to target: URL, attempts: Int = 1000) throws -> URL {
    let data = Data(text.utf8)
    for n in 1...attempts {
      let url = candidate(target, n)
      let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
      if fd < 0 {
        if errno == EEXIST { continue }
        throw TMSMError.outputFailed(url.path, String(cString: strerror(errno)))
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        try handle.close()
      } catch {
        try? FileManager.default.removeItem(at: url)
        throw TMSMError.outputFailed(url.path, error.localizedDescription)
      }
      return url
    }
    throw TMSMError.outputExists(target.path)
  }

  public static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }
}
