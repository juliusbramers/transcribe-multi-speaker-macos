import ArgumentParser
import Foundation

/// `--speakers 1-4|auto`.
public enum SpeakerCount: Equatable, Sendable, ExpressibleByArgument, CustomStringConvertible {
  public static let maximum = 4
  case auto
  case exactly(Int)

  public init?(argument: String) {
    let value = argument.lowercased()
    if value == "auto" {
      self = .auto
    } else if let n = Int(value), (1...SpeakerCount.maximum).contains(n) {
      self = .exactly(n)
    } else {
      return nil
    }
  }

  public var description: String {
    switch self {
    case .auto: return "auto"
    case .exactly(let n): return String(n)
    }
  }

  /// Most speakers the transcript may contain.
  public var limit: Int {
    switch self {
    case .auto: return SpeakerCount.maximum
    case .exactly(let n): return n
    }
  }

  public static var allValueStrings: [String] { ["auto", "1", "2", "3", "4"] }
}

/// The flags of a transcription run. A run never asks anything: missing flags use defaults.
public struct RunOptions: ParsableArguments, Sendable {
  @Argument(help: "Audio or video file: m4a, mp3, ogg/opus, wav, flac, mp4, mov, …")
  public var file: String

  @Option(help: "Number of speakers: 1-4 or auto (at most 4).")
  public var speakers: SpeakerCount = .auto

  @Option(help: "Spoken language as an ISO 639-1 code (de, en, …) or auto.")
  public var language: String = "auto"

  @Option(
    name: [.short, .long],
    help: "Output file or folder (default: the Desktop). Existing files are never overwritten.")
  public var output: String?

  @Option(
    help: ArgumentHelp(
      "Preset for this run: \((Catalogue.shared.presetNames + [Config.individual]).joined(separator: ", ")) (default: the configured preset)."
    ))
  public var preset: String?

  @Flag(help: "Print the result as JSON on stdout instead of the output path.")
  public var json = false

  @Flag(name: [.short, .long], help: "No progress on stderr.")
  public var quiet = false

  public init() {}

  /// `auto` → nil; `de-DE` / `de_DE` / `DE` → `de`.
  public var languageCode: String? {
    let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
      .map(String.init)
    return code == nil || code == "auto" ? nil : code
  }
}
