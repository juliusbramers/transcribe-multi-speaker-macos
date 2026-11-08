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
  @Argument(help: "Audio or video file: m4a, mp3, ogg/opus, wav, flac, mp4, mov, …; - reads stdin.")
  public var file: String

  @Option(help: "Number of speakers: 1-4 or auto (at most 4).")
  public var speakers: SpeakerCount = .auto

  @Option(help: "Spoken language as an ISO 639-1 code (de, en, …) or auto.")
  public var language: String = "auto"

  @Option(
    name: [.short, .long],
    help:
      "Output file or folder (default: the Desktop); - writes the Markdown to stdout. Existing files are never overwritten."
  )
  public var output: String?

  @Option(
    help: ArgumentHelp(
      "Name for the heading and the output file (default: the input's file name; stdin for -).",
      valueName: "name"))
  public var name: String?

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

  /// Usage mistakes fail at parse time, with exit code 64, before anything runs.
  public mutating func validate() throws {
    if let preset {
      let names = Catalogue.shared.presetNames + [Config.individual]
      guard names.contains(preset.lowercased()) else {
        throw ValidationError(
          "Unknown preset '\(preset)'. Choose one of: \(names.joined(separator: ", ")).")
      }
    }
    guard RunOptions.isLanguageSyntax(language) else {
      throw ValidationError(
        "--language takes auto or a two-letter ISO 639-1 code such as de or en (de-DE works too), not '\(language)'."
      )
    }
  }

  /// `auto`, `de`, `de-DE`, `de_DE`, `DE`.
  public static func isLanguageSyntax(_ value: String) -> Bool {
    if value.lowercased() == "auto" { return true }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
      .flatMap { $0.split(separator: "_", omittingEmptySubsequences: false) }
    guard let code = parts.first, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return false }
    return parts.dropFirst().allSatisfy {
      $0.count >= 2 && $0.count <= 4 && $0.allSatisfy(\.isASCII)
        && $0.allSatisfy { $0.isLetter || $0.isNumber }
    }
      && parts.count <= 3
  }

  public var readsStdin: Bool { file == AudioInput.stdinName }
  public var writesStdout: Bool { output == "-" }

  /// `auto` → nil; `de-DE` / `de_DE` / `DE` → `de`.
  public var languageCode: String? {
    let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
      .map(String.init)
    return code == nil || code == "auto" ? nil : code
  }
}
