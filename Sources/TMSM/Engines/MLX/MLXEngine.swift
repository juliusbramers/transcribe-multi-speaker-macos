import AudioCommon
import Darwin
import Foundation

/// MLX models run through speech-swift: Qwen3-ASR and Cohere Transcribe for speech, the Qwen3
/// forced aligner for word timings. Everything lives under `<TMSM_HOME>/models/mlx/`.
///
/// Which preset uses which entry is decided in `Presets`, not here.
public enum MLXEngine {
  public static let folder = "mlx"

  /// Qwen3-ASR's languages with an ISO 639-1 code (Cantonese and Filipino have none).
  public static let qwen3Languages = [
    "ar", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "hi", "hu", "id", "it", "ja",
    "ko", "mk", "ms", "nl", "pl", "pt", "ro", "ru", "sv", "th", "tr", "vi", "zh",
  ]
  /// Cohere Transcribe's 14 languages.
  public static let cohereLanguages = [
    "ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh",
  ]

  /// The forced aligner every MLX entry uses for word timings.
  public static let aligner = MLXModel(
    repo: "aufklarer/Qwen3-ForcedAligner-0.6B-8bit", name: "Qwen3 forced aligner 0.6B 8-bit",
    files: qwen3Files + ["quantize_config.json"])

  /// Files besides config.json and the weights that each loader reads.
  static let qwen3Files = ["vocab.json", "merges.txt", "tokenizer_config.json"]
  static let cohereFiles = ["tokenizer.model", "tokenizer_config.json"]

  static let qwen3Bit8 = MLXTranscriberSpec(
    id: "qwen3-asr-1.7b-8bit", kind: .qwen3,
    model: MLXModel(
      repo: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", name: "Qwen3-ASR 1.7B 8-bit", files: qwen3Files),
    languages: qwen3Languages, downloadMB: 2354 + 1222, license: "Apache-2.0")
  static let qwen3Bit5 = MLXTranscriberSpec(
    id: "qwen3-asr-1.7b-5bit", kind: .qwen3,
    model: MLXModel(
      repo: "aufklarer/Qwen3-ASR-1.7B-MLX-5bit", name: "Qwen3-ASR 1.7B 5-bit", files: qwen3Files),
    languages: qwen3Languages, downloadMB: 2332 + 1222, license: "Apache-2.0")
  static let cohereFP16 = MLXTranscriberSpec(
    id: "cohere-transcribe-2b-fp16", kind: .cohere,
    model: MLXModel(
      repo: "aufklarer/Cohere-Transcribe-2B-MLX-FP16", name: "Cohere Transcribe 2B fp16",
      files: cohereFiles),
    languages: cohereLanguages, downloadMB: 3942 + 1222, license: "Apache-2.0")

  static let transcribers = [qwen3Bit8, qwen3Bit5, cohereFP16]

  public static let registration = EngineRegistration(
    engine: folder, entries: transcribers.map(\.entry) + [router])

  /// The entry behind a routed preset. Its choices per language come from the preset table.
  static var router: CatalogueEntry {
    let routing = Presets.extreme.routing ?? LanguageRouting(byLanguage: [:], fallback: "")
    let candidates =
      FluidAudioEngine.registration.entries + transcribers.map(\.entry)
    let routed = candidates.filter { routing.entries.contains($0.id) }
    return CatalogueEntry(
      id: Presets.extremeRouter, name: "Best model per language", engine: folder,
      languages: Array(Set(routed.flatMap(\.languages))).sorted(),
      downloadMB: routed.map(\.downloadMB).reduce(0, +), license: "see routed models",
      gated: false,
      factory: .transcription { home in
        RoutedTranscriber(routing: routing, home: home)
      },
      storage: { home in routed.flatMap { $0.storage(home) } },
      prepare: { home, progress in
        for id in routing.entries where id != Presets.extremeRouter {
          try await Catalogue.shared.entry(id).prepare(home, progress)
        }
      })
  }

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

  /// Downloads a model's files without loading it. Files already on disk are skipped.
  static func download(_ model: MLXModel, _ home: TMSMHome, _ progress: Progress) async throws {
    redirectCaches(home)
    let needed = !isDownloaded(model, home)
    if needed {
      progress.stage("Downloading \(model.name)")
    } else {
      progress.activity("Checking \(model.name)")
    }
    try await HuggingFaceDownloader.downloadWeights(
      modelId: model.repo, to: directory(model, home), additionalFiles: model.files,
      progressHandler: { fraction in if needed { progress.update(fraction) } })
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

  /// True when the folder already holds the weights, so loading needs no download.
  static func isDownloaded(_ model: MLXModel, _ home: TMSMHome) -> Bool {
    let dir = directory(model, home)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
  }
}

/// One Hugging Face repo.
public struct MLXModel: Sendable, Equatable {
  public var repo: String
  public var name: String
  /// Files besides config.json and the weights.
  public var files: [String]
}

/// A speech-to-text entry: which model, and how speech-swift runs it.
struct MLXTranscriberSpec: Sendable {
  enum Kind: Sendable { case qwen3, cohere }

  var id: String
  var kind: Kind
  var model: MLXModel
  var languages: [String]
  /// Model plus aligner, in MB.
  var downloadMB: Int
  var license: String

  var entry: CatalogueEntry {
    let spec = self
    return CatalogueEntry(
      id: id, name: model.name, engine: MLXEngine.folder, languages: languages,
      downloadMB: downloadMB, license: license, gated: false,
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
