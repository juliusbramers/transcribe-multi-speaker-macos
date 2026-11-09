import Foundation

/// One model tmsm can use, registered by the engine that runs it.
public struct CatalogueEntry: Sendable {
  /// `joint`: one model that writes the words and labels the speakers.
  public enum Kind: String, Sendable { case transcription, speakers, joint }

  public enum Factory: Sendable {
    case transcription(@Sendable (TMSMHome) -> any TranscriptionEngine)
    case speakers(@Sendable (TMSMHome) -> any SpeakerEngine)
    case joint(@Sendable (TMSMHome) -> any JointEngine)
  }

  public var id: String
  public var name: String
  /// Engine folder under `models/`, e.g. "fluidaudio".
  public var engine: String
  /// ISO 639-1 codes; empty means the model does not care (speaker models).
  public var languages: [String]
  public var downloadMB: Int
  public var license: String
  public var gated: Bool
  public var factory: Factory
  /// Where the model lives on disk, for setup's "delete models no longer needed".
  public var storage: @Sendable (TMSMHome) -> [URL]
  /// Downloads everything the entry needs, without running it. Default: one run on 1 s of
  /// silence (which downloads as a side effect); engines that can download directly override it.
  public var prepare: @Sendable (TMSMHome, Progress) async throws -> Void

  public var kind: Kind {
    switch factory {
    case .transcription: return .transcription
    case .speakers: return .speakers
    case .joint: return .joint
    }
  }

  public init(
    id: String, name: String, engine: String, languages: [String], downloadMB: Int,
    license: String, gated: Bool, factory: Factory,
    storage: @escaping @Sendable (TMSMHome) -> [URL],
    prepare: (@Sendable (TMSMHome, Progress) async throws -> Void)? = nil
  ) {
    self.id = id
    self.name = name
    self.engine = engine
    self.languages = languages
    self.downloadMB = downloadMB
    self.license = license
    self.gated = gated
    self.factory = factory
    self.storage = storage
    self.prepare = prepare ?? { home, progress in try await factory.runOnSilence(home, progress) }
  }
}

/// What one engine contributes. Each engine folder under `Engines/` provides one.
public struct EngineRegistration: Sendable {
  public var engine: String
  public var entries: [CatalogueEntry]

  public init(engine: String, entries: [CatalogueEntry]) {
    self.engine = engine
    self.entries = entries
  }
}

public struct Catalogue: Sendable {
  public static let defaultPreset = "default"
  /// Every engine tmsm ships.
  public static let registrations: [EngineRegistration] = [
    FluidAudioEngine.registration, MLXEngine.registration,
  ]
  public static let shared = Catalogue(registrations)

  public let entries: [CatalogueEntry]
  public let presets: [Preset]

  /// Presets come from the preset table (`Presets.all`), entries from the engines.
  public init(_ registrations: [EngineRegistration], presets: [Preset] = Presets.all) {
    entries = registrations.flatMap(\.entries)
    self.presets = presets
  }

  public var presetNames: [String] { presets.map(\.name) }

  public func preset(named name: String) throws -> Preset {
    guard let preset = presets.first(where: { $0.name == name.lowercased() }) else {
      throw TMSMError.unknownPreset(name)
    }
    return preset
  }

  public func entry(_ id: String) throws -> CatalogueEntry {
    guard let entry = entries.first(where: { $0.id == id }) else {
      throw TMSMError.unknownModel(id)
    }
    return entry
  }
}

extension CatalogueEntry.Factory {
  /// One run on 1 s of silence: loads (and so downloads) the model.
  func runOnSilence(_ home: TMSMHome, _ progress: Progress) async throws {
    let silence = Audio(samples: [Float](repeating: 0, count: Audio.sampleRate))
    switch self {
    case .transcription(let make):
      _ = try await make(home).transcribe(silence, language: nil, progress: progress)
    case .speakers(let make):
      _ = try await make(home).label(silence, maxSpeakers: 4, progress: progress)
    case .joint(let make):
      _ = try await make(home).transcribe(
        silence, language: nil, maxSpeakers: 4, progress: progress)
    }
  }
}
