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
    subcommands: [Transcribe.self, Setup.self, Install.self, Update.self, Uninstall.self],
    defaultSubcommand: Transcribe.self)
}

/// Prints `tmsm: <message>` on stderr and exits non-zero.
func fail(_ error: Error) -> ExitCode {
  FileHandle.standardError.write(Data("tmsm: \(error.localizedDescription)\n".utf8))
  return ExitCode.failure
}

/// The first launch in a terminal asks for a preset and downloads it. Without a terminal
/// nothing is asked and runs use the default preset.
func firstLaunch(_ home: TMSMHome, console: Console) async throws {
  guard console.isInteractive, !FileManager.default.fileExists(atPath: home.configFile.path)
  else { return }
  console.say("Welcome to tmsm.")
  let setup = ModelSetup(home: home)
  let config = try setup.ask(console, current: Config())
  try await setup.apply(
    config, console: console, progress: Progress(mode: .bar), deleteUnused: false)
}

struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Transcribe a file (the default command: `tmsm <file>`).")

  @OptionGroup var options: RunOptions

  func run() async throws {
    let home = TMSMHome.resolve()
    let progress = Progress(mode: Progress.mode(quiet: options.quiet))
    var runTemp: URL?
    defer { if let runTemp { home.removeRunTemporary(runTemp) } }
    do {
      runTemp = try home.activate()
      if options.preset == nil && !options.json && !options.quiet {
        try await firstLaunch(home, console: TerminalConsole())
      }
      let result = try await Pipeline(home: home).run(options, progress: progress)
      progress.finish()
      print(options.json ? result.json : result.output)
    } catch {
      progress.finish()
      throw fail(error)
    }
  }
}

struct Setup: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Choose the preset or individual models, download them, delete unused ones.",
    discussion: """
      Without options it asks in the terminal; with options it asks nothing (for scripts). \
      A gated model needs a Hugging Face token: typed in hidden and kept in the Keychain, \
      or passed as HF_TOKEN.
      """)

  @Option(help: ArgumentHelp("Preset to use from now on (see --list).", valueName: "name"))
  var preset: String?

  @Option(
    help: ArgumentHelp("Speech-to-text model id; implies --preset individual.", valueName: "id"))
  var transcription: String?

  @Option(help: ArgumentHelp("Speaker model id; implies --preset individual.", valueName: "id"))
  var speakers: String?

  @Flag(help: "Delete downloaded models the new setting no longer uses, without asking.")
  var deleteUnused = false

  @Flag(help: "Keep downloaded models the new setting no longer uses, without asking.")
  var keepUnused = false

  @Flag(help: "List presets and models, mark the configured one, and exit.")
  var list = false

  func validate() throws {
    if deleteUnused && keepUnused {
      throw ValidationError("Use --delete-unused or --keep-unused, not both.")
    }
  }

  func run() async throws {
    let home = TMSMHome.resolve()
    let console = TerminalConsole()
    var runTemp: URL?
    defer { if let runTemp { home.removeRunTemporary(runTemp) } }
    do {
      let setup = ModelSetup(home: home)
      let current = try Config.load(from: home.configFile)
      if list {
        print(setup.listing(current: current))
        return
      }
      let config: Config
      if preset == nil && transcription == nil && speakers == nil {
        guard console.isInteractive else {
          throw SetupError.needsTerminal("Pass --preset, or --transcription and --speakers.")
        }
        config = try setup.ask(console, current: current)
      } else {
        config = try setup.config(
          preset: preset, transcription: transcription, speakers: speakers, current: current)
      }
      runTemp = try home.activate()
      let progress = Progress(mode: Progress.mode(quiet: false))
      try await setup.apply(
        config, console: console, progress: progress,
        deleteUnused: deleteUnused ? true : keepUnused ? false : nil)
      print(home.configFile.path)
    } catch {
      throw fail(error)
    }
  }
}

struct Install: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Put tmsm in ~/.tmsm and add it to PATH in your login profile.",
    discussion: "Run from the unpacked release folder; the install line does this for you.")

  @Flag(help: "Don't ask for a preset afterwards (the first transcription uses the default).")
  var noSetup = false

  func run() async throws {
    let console = TerminalConsole()
    do {
      let installer = Installer()
      // The folder the running tmsm is in: the unpacked release, or ~/.tmsm itself.
      let executable =
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
      let source = executable.resolvingSymlinksInPath().deletingLastPathComponent()
      if try installer.installProgram(from: source) {
        console.say("Installed tmsm \(TMSMVersion.string) in \(installer.programFolder.path).")
      }
      if try installer.addPathLine() {
        console.say("Added \(installer.programFolder.path) to PATH in \(installer.profile.path).")
      }
      if !installer.isOnPath(ProcessInfo.processInfo.environment) {
        console.say("Open a new terminal window to use `tmsm`.")
      }
      print(installer.executable.path)
      if !noSetup {
        let home = TMSMHome.resolve()
        let runTemp = try home.activate()
        defer { home.removeRunTemporary(runTemp) }
        try await firstLaunch(home, console: console)
      }
    } catch {
      throw fail(error)
    }
  }
}

struct Update: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Install the latest release (checked against SHA256SUMS). Models stay.")

  @Flag(help: "Only print the latest version; exit 0 if it is newer than this one, else 1.")
  var check = false

  @Option(
    help: ArgumentHelp(
      "Install this version instead of the latest, e.g. 0.1.0.", valueName: "version"))
  var to: String?

  func run() async throws {
    let console = TerminalConsole()
    do {
      let updater = Updater()
      let target = try to ?? updater.latestVersion()
      let newer = Updater.isNewer(target, than: TMSMVersion.string)
      if check {
        print(target)
        if !newer { throw ExitCode.failure }
        return
      }
      guard newer || to != nil else {
        console.say("tmsm \(TMSMVersion.string) is the latest version.")
        print(Installer().executable.path)
        return
      }
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("tmsm-update-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      console.say("Downloading tmsm \(target)…")
      let unpacked = try updater.fetch(target, into: folder)
      let install = Process()
      install.executableURL = unpacked.appendingPathComponent("tmsm")
      install.arguments = ["install", "--no-setup"]
      try install.run()
      install.waitUntilExit()
      guard install.terminationStatus == 0 else { throw ExitCode(install.terminationStatus) }
    } catch let exit as ExitCode {
      throw exit
    } catch {
      throw fail(error)
    }
  }
}

struct Uninstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Remove tmsm, its models, config, caches, Keychain token and PATH line.",
    discussion: "Transcripts you wrote stay where they are.")

  @Flag(name: [.short, .long], help: "Don't ask for confirmation (needed without a terminal).")
  var yes = false

  func run() throws {
    let console = TerminalConsole()
    let uninstaller = Uninstaller(home: TMSMHome.resolve(), installer: Installer())
    let plan = uninstaller.plan()
    console.say("This removes:")
    for item in plan { console.say("  - \(Uninstaller.describe(item))") }
    if !yes {
      guard console.isInteractive else {
        throw fail(SetupError.needsTerminal("Pass --yes to uninstall without a terminal."))
      }
      guard console.confirm("Remove tmsm?", default: false) else {
        throw fail(SetupError.cancelled)
      }
    }
    let errors = uninstaller.run(plan)
    for error in errors { console.say("tmsm: \(error.localizedDescription)") }
    guard errors.isEmpty else { throw ExitCode.failure }
    console.say("tmsm removed.")
  }
}
