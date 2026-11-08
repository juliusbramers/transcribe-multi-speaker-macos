@preconcurrency import AVFoundation
import Dispatch
import FluidAudio
import Foundation
import Synchronization

/// Any audio file → 16 kHz mono floats.
///
/// AVFoundation first (through FluidAudio's `AudioConverter`): m4a, mp3, aac, wav, flac, caf,
/// WhatsApp ogg/opus and the audio track of mp4/mov. If that fails and `ffmpeg` is on PATH,
/// ffmpeg decodes instead.
public enum AudioDecoder {
  public static func decode(
    _ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Audio {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TMSMError.inputNotFound(url.path)
    }
    let avError: Error
    do {
      let samples = try AudioConverter(sampleRate: Double(Audio.sampleRate))
        .resampleAudioFile(url)
      let expected = try expectedSamples(url)
      if samples.isEmpty {
        avError = TMSMError.emptyAudio(url.path)
      } else if isTruncated(decoded: samples.count, expected: expected) {
        // FluidAudio's reader treats any read error after the first chunk as the end of the file
        // (to tolerate MP3/AAC length estimates). A damaged file must not become half a transcript.
        avError = TMSMError.undecodableAudio(
          url.path,
          "AVFoundation stopped at \(seconds(samples.count)) of \(seconds(expected))")
      } else {
        return Audio(samples: samples)
      }
    } catch {
      avError = error
    }
    guard let ffmpeg = findExecutable("ffmpeg", path: environment["PATH"]) else {
      throw TMSMError.undecodableAudio(
        url.path, "\(avError.localizedDescription) (install ffmpeg for more formats)")
    }
    let samples = try decodeWithFFmpeg(url, ffmpeg: ffmpeg)
    guard !samples.isEmpty else { throw TMSMError.emptyAudio(url.path) }
    return Audio(samples: samples)
  }

  static func decodeWithFFmpeg(_ url: URL, ffmpeg: URL) throws -> [Float] {
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = [
      "-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.path,
      "-vn", "-ac", "1", "-ar", String(Audio.sampleRate), "-f", "f32le", "pipe:1",
    ]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Read stderr on the side so a chatty ffmpeg never blocks on a full pipe.
    let errData = Mutex<Data>(Data())
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
      let d = err.fileHandleForReading.readDataToEndOfFile()
      errData.withLock { $0 = d }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    group.wait()
    guard process.terminationStatus == 0 else {
      let message = errData.withLock { String(decoding: $0, as: UTF8.self) }
      throw TMSMError.undecodableAudio(
        url.path, "ffmpeg: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
  }

  /// Samples at 16 kHz that AVFoundation's length estimate promises.
  static func expectedSamples(_ url: URL) throws -> Int {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard rate > 0 else { return 0 }
    return Int((Double(file.length) * Double(Audio.sampleRate) / rate).rounded(.down))
  }

  /// Length estimates of packetized formats overshoot by a few hundred frames; one second of
  /// slack separates that from a read that stopped early.
  public static func isTruncated(decoded: Int, expected: Int) -> Bool {
    decoded + Audio.sampleRate < expected
  }

  static func seconds(_ samples: Int) -> String {
    String(format: "%.1f s", Double(samples) / Double(Audio.sampleRate))
  }

  /// First executable `name` in a PATH string.
  public static func findExecutable(_ name: String, path: String?) -> URL? {
    for dir in (path ?? "").split(separator: ":") where !dir.isEmpty {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }
}
