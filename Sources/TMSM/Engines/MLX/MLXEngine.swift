import Darwin
import Foundation

/// MLX models run through speech-swift: Qwen3-ASR and Voxtral Mini for speech, MOSS for speech
/// and speakers together, the Qwen3 forced aligner for word timings. Everything lives under
/// `<TMSM_HOME>/models/mlx/`.
///
/// Which preset uses which entry is decided in `Presets`, not here.
public enum MLXEngine {
  public static let folder = "mlx"

  /// Qwen3-ASR's languages with an ISO 639-1 code (Cantonese and Filipino have none).
  public static let qwen3Languages = [
    "ar", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "hi", "hu", "id", "it", "ja",
    "ko", "mk", "ms", "nl", "pl", "pt", "ro", "ru", "sv", "th", "tr", "vi", "zh",
  ]
  /// Voxtral Mini's 8 languages.
  public static let voxtralLanguages = ["de", "en", "es", "fr", "hi", "it", "nl", "pt"]

  static let qwen3Bit8 = MLXTranscriberSpec(
    id: "qwen3-asr-1.7b-8bit", kind: .qwen3, model: qwen3Bit8Model, languages: qwen3Languages,
    license: "Apache-2.0")
  static let qwen3Bit5 = MLXTranscriberSpec(
    id: "qwen3-asr-1.7b-5bit", kind: .qwen3, model: qwen3Bit5Model, languages: qwen3Languages,
    license: "Apache-2.0")
  static let voxtralBit8 = MLXTranscriberSpec(
    id: "voxtral-mini-3b-8bit", kind: .voxtral, model: voxtralBit8Model,
    languages: voxtralLanguages, license: "Apache-2.0")

  static let transcribers = [qwen3Bit8, qwen3Bit5, voxtralBit8]

  /// Languages MOSS-Transcribe-Diarize is known to handle (its card claims 50+ but names
  /// these; tmsm routes only what it can stand behind).
  public static let mossLanguages = [
    "de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "th", "tr", "ur", "vi", "zh",
  ]

  public static let moss = CatalogueEntry(
    id: "moss-transcribe-diarize-0.9b-8bit", name: mossBit8Model.name, engine: folder,
    languages: mossLanguages, downloadMB: mossBit8Model.megabytes, license: "Apache-2.0",
    gated: false,
    factory: .joint { home in MossTranscriber(model: mossBit8Model, home: home) },
    storage: { home in [MLXEngine.directory(mossBit8Model, home)] },
    prepare: { home, progress in try await MLXEngine.download(mossBit8Model, home, progress) })

  public static let registration = EngineRegistration(
    engine: folder, entries: transcribers.map(\.entry) + [moss])

  static func modelsRoot(_ home: TMSMHome) -> URL { home.models(engine: folder) }

  /// `models/mlx/<org>/<name>`: one folder per Hugging Face repo.
  static func directory(_ model: MLXModel, _ home: TMSMHome) -> URL {
    var url = modelsRoot(home)
    for part in model.repo.split(separator: "/") {
      url.appendPathComponent(String(part), isDirectory: true)
    }
    return url
  }

  /// speech-swift falls back to `~/Library/Caches/qwen3-speech` for any model it is not handed
  /// a folder for; point that at the root too.
  static func redirectCaches(_ home: TMSMHome) {
    setenv("QWEN3_CACHE_DIR", home.cache.appendingPathComponent("speech-swift").path, 1)
  }

  /// Makes the model's pinned bundle complete: no network when it already is, otherwise the
  /// missing files from the pinned commit, hash-checked.
  static func download(_ model: MLXModel, _ home: TMSMHome, _ progress: Progress) async throws {
    redirectCaches(home)
    guard !isDownloaded(model, home) else { return }
    progress.stage("Downloading \(model.name)")
    try await PinnedDownload.ensure(
      repo: model.repo, revision: model.revision, files: model.files,
      into: directory(model, home)
    ) { done, total in progress.update(total > 0 ? Double(done) / Double(total) : 1) }
  }

  /// speech-swift prints loading notes to stdout, which belongs to tmsm's result (the path or
  /// `--json`), and tokenizer notes to stderr, which belongs to the progress line. Sends the
  /// given descriptors to /dev/null while `body` runs.
  static func quiet<T>(
    _ descriptors: [Int32] = [STDOUT_FILENO], _ body: () async throws -> T
  ) async rethrows -> T {
    fflush(stdout)
    fflush(stderr)
    let null = open("/dev/null", O_WRONLY)
    let saved = descriptors.map { fd -> (Int32, Int32) in
      let copy = dup(fd)
      if copy >= 0, null >= 0 { dup2(null, fd) }
      return (fd, copy)
    }
    defer {
      fflush(stdout)
      fflush(stderr)
      for (fd, copy) in saved where copy >= 0 {
        dup2(copy, fd)
        close(copy)
      }
      if null >= 0 { close(null) }
    }
    return try await body()
  }

  /// Downloads (with a bar) if needed, then loads with both outputs quiet. The progress line
  /// shows "Loading" and resumes once the model is in memory.
  static func load<T>(
    _ model: MLXModel, _ home: TMSMHome, _ progress: Progress,
    _ body: (URL) async throws -> T
  ) async throws -> T {
    try await download(model, home, progress)
    progress.activity("Loading \(model.name)")
    return try await quiet([STDOUT_FILENO, STDERR_FILENO]) {
      try await body(directory(model, home))
    }
  }

  /// True when the complete pinned bundle is on disk, so loading needs no network.
  static func isDownloaded(_ model: MLXModel, _ home: TMSMHome) -> Bool {
    PinnedDownload.isComplete(directory(model, home), revision: model.revision, files: model.files)
  }
}

/// One Hugging Face repo at one commit.
public struct MLXModel: Sendable, Equatable {
  public var repo: String
  public var name: String
  /// The immutable commit every file comes from.
  public var revision: String
  /// Every file the loaders read, with its size and hash.
  public var files: [PinnedFile]

  /// Download size in MB.
  public var megabytes: Int { Int(files.reduce(Int64(0)) { $0 + $1.size } / 1_000_000) }
}

/// A speech-to-text entry: which model, and how speech-swift runs it.
struct MLXTranscriberSpec: Sendable {
  enum Kind: Sendable { case qwen3, voxtral }

  var id: String
  var kind: Kind
  var model: MLXModel
  var languages: [String]
  var license: String

  var entry: CatalogueEntry {
    let spec = self
    return CatalogueEntry(
      id: id, name: model.name, engine: MLXEngine.folder, languages: languages,
      downloadMB: model.megabytes + MLXEngine.aligner.megabytes, license: license, gated: false,
      factory: .transcription { home in MLXTranscriber(spec: spec, home: home) },
      storage: { home in
        [MLXEngine.directory(spec.model, home), MLXEngine.directory(MLXEngine.aligner, home)]
      },
      prepare: { home, progress in
        try await MLXEngine.download(spec.model, home, progress)
        try await MLXEngine.download(MLXEngine.aligner, home, progress)
      })
  }
}
