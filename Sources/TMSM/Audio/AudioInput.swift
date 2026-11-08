import Foundation

/// Audio that arrives on stdin (`tmsm -`): copied into a file of the run's own, named with an
/// extension that matches its content, so the decoders can tell the format.
public enum AudioInput {
  /// The file name `-` means stdin.
  public static let stdinName = "-"

  /// The extension for a file starting with `head`, from its magic bytes. `nil`: unknown, which
  /// the decoders may still read (AVFoundation sniffs, ffmpeg probes).
  public static func sniff(_ head: Data) -> String? {
    let b = [UInt8](head.prefix(16))
    func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
      b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
    }
    if starts(Array("OggS".utf8)) { return "ogg" }
    if starts(Array("fLaC".utf8)) { return "flac" }
    if starts(Array("RIFF".utf8)) && starts(Array("WAVE".utf8), at: 8) { return "wav" }
    if starts(Array("FORM".utf8)) && starts(Array("AIF".utf8), at: 8) { return "aiff" }
    if starts(Array("caff".utf8)) { return "caf" }
    if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
    if starts(Array("ftyp".utf8), at: 4) {
      return starts(Array("qt  ".utf8), at: 8) ? "mov" : "m4a"
    }
    if starts(Array("ID3".utf8)) { return "mp3" }
    if b.count >= 2 && b[0] == 0xFF {
      if b[1] & 0xF6 == 0xF0 { return "aac" }  // ADTS
      if b[1] & 0xE0 == 0xE0 { return "mp3" }  // MPEG audio frame sync
    }
    return nil
  }

  /// Copies all of `input` into `folder`/stdin.<ext> and returns the file. Throws on empty input.
  public static func copy(from input: FileHandle, into folder: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = folder.appendingPathComponent("stdin.partial")
    guard fm.createFile(atPath: partial.path, contents: nil) else {
      throw TMSMError.outputFailed(partial.path, "can't create the stdin copy")
    }
    var head = Data()
    do {
      let out = try FileHandle(forWritingTo: partial)
      defer { try? out.close() }
      while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
        if head.count < 16 { head.append(chunk.prefix(16 - head.count)) }
        try out.write(contentsOf: chunk)
      }
    } catch {
      try? fm.removeItem(at: partial)
      throw TMSMError.undecodableAudio("stdin", error.localizedDescription)
    }
    guard !head.isEmpty else {
      try? fm.removeItem(at: partial)
      throw TMSMError.emptyAudio("stdin")
    }
    let file = folder.appendingPathComponent("stdin." + (sniff(head) ?? "audio"))
    try? fm.removeItem(at: file)
    try fm.moveItem(at: partial, to: file)
    return file
  }
}
