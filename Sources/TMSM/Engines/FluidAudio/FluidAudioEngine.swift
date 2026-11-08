import CoreML
import FluidAudio
import Foundation

/// Core ML models run through FluidAudio: Parakeet for speech, Nemotron-3 for speakers.
/// Everything lives under `<TMSM_HOME>/models/fluidaudio/`.
public enum FluidAudioEngine {
  public static let folder = "fluidaudio"

  /// The 25 languages of Parakeet v3 and Ultra.
  public static let parakeetLanguages = [
    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv",
    "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
  ]

  public static let registration = EngineRegistration(
    engine: folder,
    entries: [
      parakeet(
        id: "parakeet-v3", name: "Parakeet TDT 0.6B v3", version: .v3, repo: .parakeetV3,
        downloadMB: 480),
      parakeet(
        id: "parakeet-ultra", name: "Parakeet Ultra", version: .ultra, repo: .parakeetUltra,
        downloadMB: 630),
      nemotron(id: "nemotron3-c128-split-w8a8", preset: "c128-split-w8a8", downloadMB: 95),
      nemotron(id: "nemotron3-offline", preset: "offline", downloadMB: 190),
    ],
    presets: [
      Preset(
        name: "fast", transcription: "parakeet-v3", speakers: "nemotron3-c128-split-w8a8",
        summary: "Parakeet v3 + Nemotron-3 c128-split-w8a8, ~1 GB RAM, 25 languages"),
      Preset(
        name: "default", transcription: "parakeet-ultra", speakers: "nemotron3-offline",
        summary: "Parakeet Ultra + Nemotron-3 offline, ~1.5 GB RAM, 25 languages"),
    ])

  static func modelsRoot(_ home: TMSMHome) -> URL { home.models(engine: folder) }

  static func parakeet(
    id: String, name: String, version: AsrModelVersion, repo: Repo, downloadMB: Int
  ) -> CatalogueEntry {
    CatalogueEntry(
      id: id, name: name, engine: folder, languages: parakeetLanguages, downloadMB: downloadMB,
      license: "CC-BY-4.0", gated: false,
      factory: .transcription { home in
        ParakeetTranscriber(name: name, version: version, repo: repo, home: home)
      },
      storage: { home in [modelsRoot(home).appendingPathComponent(repo.folderName)] })
  }

  static func nemotron(id: String, preset: String, downloadMB: Int) -> CatalogueEntry {
    CatalogueEntry(
      id: id, name: "Nemotron-3 Diarization (\(preset))", engine: folder, languages: [],
      downloadMB: downloadMB, license: "OpenMDW-1.1", gated: false,
      factory: .speakers { home in NemotronLabeller(preset: preset, home: home) },
      storage: { home in
        // The repo folder holds every Nemotron-3 preset; setup removes one bundle at a time.
        guard let config = Nemotron3Config.preset(named: preset) else { return [] }
        return [
          modelsRoot(home).appendingPathComponent(Repo.nemotron3Diarization.folderName)
            .appendingPathComponent(config.hubSubdirectory)
            .appendingPathComponent(config.modelFileName)
        ]
      })
  }

  /// Download and compile phases → the progress line. FluidAudio also reports these phases for
  /// models that are already on disk; only a download with files still missing gets a bar.
  static func downloadHandler(_ name: String, _ progress: Progress) -> ProgressHandler {
    { update in
      switch update.phase {
      case .listing:
        progress.activity("Checking \(name)")
      case .downloading(let done, let total) where done < total:
        progress.stage("Downloading \(name)")
        progress.update(update.fractionCompleted)
      case .downloading:
        break
      case .compiling:
        progress.activity("Preparing \(name)")
      }
    }
  }
}

struct ParakeetTranscriber: TranscriptionEngine {
  let name: String
  let version: AsrModelVersion
  let repo: Repo
  let home: TMSMHome

  func transcribe(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word] {
    progress.activity("Loading \(name)")
    let directory = FluidAudioEngine.modelsRoot(home).appendingPathComponent(repo.folderName)
    let models = try await AsrModels.downloadAndLoad(
      to: directory, version: version,
      progressHandler: FluidAudioEngine.downloadHandler(name, progress))
    let manager = AsrManager(config: .default, models: models)

    progress.stage("Transcribing")
    let stream = await manager.transcriptionProgressStream
    let watcher = Task {
      for try await fraction in stream { progress.update(fraction) }
    }
    defer { watcher.cancel() }

    var state = TdtDecoderState.make()
    let result = try await manager.transcribe(
      audio.samples, decoderState: &state, language: language.flatMap(Language.init(rawValue:)))
    progress.update(1)
    await manager.cleanup()

    return buildWordTimings(from: result.tokenTimings ?? []).map {
      Word($0.word, $0.startTime, $0.endTime)
    }
  }
}

struct NemotronLabeller: SpeakerEngine {
  let preset: String
  let home: TMSMHome

  func label(_ audio: Audio, maxSpeakers: Int, progress: Progress) async throws -> SpeakerTrack {
    guard let config = Nemotron3Config.preset(named: preset) else {
      throw TMSMError.unknownModel("nemotron3-\(preset)")
    }
    let name = "Nemotron-3 (\(preset))"
    progress.activity("Loading \(name)")
    // The offline profile is GPU-only (it exceeds the ANE compiler's limits); the split
    // w8a8 profiles are built for the ANE.
    let units: MLComputeUnits = config.splitGraph ? .all : .cpuAndGPU
    let models = try await Nemotron3Models.loadFromHuggingFace(
      config: config, cacheDirectory: FluidAudioEngine.modelsRoot(home), computeUnits: units,
      progressHandler: FluidAudioEngine.downloadHandler(name, progress))

    progress.activity("Labelling speakers")
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    let (probabilities, frames) = try diarizer.processComplete(audio.samples)
    let segments = Nemotron3Diarizer.segments(
      probabilities: probabilities, frameCount: frames, numSpeakers: config.numSpeakers
    ).map { SpeakerSegment($0.speakerIndex, Double($0.startSeconds), Double($0.endSeconds)) }
    let activity = SpeakerActivity(
      frameSeconds: Double(config.outputFrameSeconds), speakers: config.numSpeakers,
      values: Array(probabilities.prefix(frames * config.numSpeakers)))
    return SpeakerTrack(segments: segments, activity: activity)
  }
}
