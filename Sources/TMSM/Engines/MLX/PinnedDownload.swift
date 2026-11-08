import CryptoKit
import Darwin
import Foundation

/// One file of a pinned model: its path in the repo, exact size and SHA-256.
public struct PinnedFile: Sendable, Equatable {
  public var path: String
  public var size: Int64
  public var sha256: String

  public init(_ path: String, _ size: Int64, _ sha256: String) {
    self.path = path
    self.size = size
    self.sha256 = sha256
  }
}

/// Downloads a model from one immutable Hugging Face commit and checks every file's hash, so
/// every installation runs exactly the same weights. A folder whose marker names the pinned
/// commit and whose files all have their pinned sizes is used as it is, with no network.
enum PinnedDownload {
  static let markerName = ".tmsm-revision"
  static let host = "https://huggingface.co"

  /// True when `dir` holds the complete pinned bundle (marker + every file at its size).
  static func isComplete(_ dir: URL, revision: String, files: [PinnedFile]) -> Bool {
    let marker = dir.appendingPathComponent(markerName)
    guard let text = try? String(contentsOf: marker, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines) == revision
    else { return false }
    return files.allSatisfy { size(of: dir.appendingPathComponent($0.path)) == $0.size }
  }

  /// Makes `dir` the complete pinned bundle. Files already there with the right size and hash
  /// are kept; the rest are downloaded from `revision` and verified before they are moved in.
  static func ensure(
    repo: String, revision: String, files: [PinnedFile], into dir: URL,
    progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void
  ) async throws {
    if isComplete(dir, revision: revision, files: files) { return }
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // One process at a time per model: others wait here, then find the bundle complete.
    let lock = try lockFile(for: dir)
    defer {
      flock(lock, LOCK_UN)
      close(lock)
    }
    if isComplete(dir, revision: revision, files: files) { return }
    // The marker goes first, so an interrupted download never looks complete.
    try? fm.removeItem(at: dir.appendingPathComponent(markerName))

    let total = files.reduce(Int64(0)) { $0 + $1.size }
    var done: Int64 = 0
    for file in files {
      let target = dir.appendingPathComponent(file.path)
      if size(of: target) == file.size, (try? sha256(of: target)) == file.sha256 {
        done += file.size
        progress(done, total)
        continue
      }
      let base = done
      let temporary = try await fetch(repo: repo, revision: revision, path: file.path) {
        progress(base + min($0, file.size), total)
      }
      defer { try? fm.removeItem(at: temporary) }
      let actualSize = size(of: temporary)
      let actualHash = try sha256(of: temporary)
      guard actualSize == file.size, actualHash == file.sha256 else {
        throw TMSMError.engine(
          "\(repo)/\(file.path) at \(revision.prefix(8)) does not match its pinned size and hash")
      }
      try fm.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: target)
      try fm.moveItem(at: temporary, to: target)
      done += file.size
      progress(done, total)
    }
    try Data((revision + "\n").utf8).write(
      to: dir.appendingPathComponent(markerName), options: .atomic)
  }

  /// An exclusive lock on `<parent>/.<name>.lock`, held until closed. Blocks while another
  /// process holds it.
  static func lockFile(for dir: URL) throws -> Int32 {
    let path = dir.deletingLastPathComponent()
      .appendingPathComponent(".\(dir.lastPathComponent).lock").path
    let fd = open(path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { throw TMSMError.engine("Can't lock \(path)") }
    while flock(fd, LOCK_EX) != 0 {
      guard errno == EINTR else {
        close(fd)
        throw TMSMError.engine("Can't lock \(path)")
      }
    }
    return fd
  }

  /// One file from `/resolve/<revision>/`, into the temp folder (which tmsm points into its
  /// root). An ephemeral session keeps cookies and caches out of ~/Library.
  static func fetch(
    repo: String, revision: String, path: String, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    let encoded = path.split(separator: "/").map {
      $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
    }.joined(separator: "/")
    guard let url = URL(string: "\(host)/\(repo)/resolve/\(revision)/\(encoded)") else {
      throw TMSMError.engine("Bad model URL for \(repo)/\(path)")
    }
    var request = URLRequest(url: url)
    request.setValue("tmsm", forHTTPHeaderField: "User-Agent")
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmsm-download-\(UUID().uuidString)")
    let delegate = DownloadDelegate(keepAt: kept, progress: progress)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let status = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.start(continuation)
        session.downloadTask(with: request).resume()
      }
    } onCancel: {
      session.invalidateAndCancel()
    }
    guard status == 200 else {
      try? FileManager.default.removeItem(at: kept)
      throw TMSMError.engine("Download of \(repo)/\(path) failed (HTTP \(status))")
    }
    return kept
  }

  static func size(of url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }

  /// SHA-256 as lowercase hex, read in 8 MB pieces.
  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Moves the finished file to `keepAt` (URLSession deletes its own copy) and reports bytes.
  private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let keepAt: URL
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, any Error>?
    private var moveError: (any Error)?

    init(keepAt: URL, progress: @escaping @Sendable (Int64) -> Void) {
      self.keepAt = keepAt
      self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<Int, any Error>) {
      lock.withLock { self.continuation = continuation }
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
      totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
      progress(totalBytesWritten)
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      do { try FileManager.default.moveItem(at: location, to: keepAt) } catch {
        lock.withLock { moveError = error }
      }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
      let (continuation, moveError) = lock.withLock {
        defer { self.continuation = nil }
        return (self.continuation, self.moveError)
      }
      if let error = error ?? moveError {
        continuation?.resume(throwing: error)
      } else {
        continuation?.resume(returning: status)
      }
    }
  }
}
