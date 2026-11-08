import ArgumentParser
import Foundation
import TMSM

@main
struct TMSMCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tmsm",
    abstract: "Turn an audio file into a Speaker 1–4 Markdown transcript, locally.",
    discussion: """
      stdout gets the path of the written file (or JSON with --json); progress goes to stderr.
      Models, config and caches live in TMSM_HOME (default: ~/Library/Application Support/tmsm).
      """,
    version: TMSMVersion.string,
    subcommands: [Transcribe.self],
    defaultSubcommand: Transcribe.self)
}

struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Transcribe a file (the default command: `tmsm <file>`).")

  @OptionGroup var options: RunOptions

  func run() async throws {
    let home = TMSMHome.resolve()
    let progress = Progress(mode: Progress.mode(quiet: options.quiet))
    defer { home.cleanTemporary() }
    do {
      try home.activate()
      let result = try await Pipeline(home: home).run(options, progress: progress)
      progress.finish()
      print(options.json ? result.json : result.output)
    } catch {
      progress.finish()
      FileHandle.standardError.write(Data("tmsm: \(error.localizedDescription)\n".utf8))
      throw ExitCode.failure
    }
  }
}
