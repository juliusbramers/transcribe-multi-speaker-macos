import Foundation

/// One model tmsm can use, registered by the engine that runs it.
public struct CatalogueEntry: Sendable {
  public enum Kind: String, Sendable { case transcription, speakers }

  public enum Factory: Sendable {
    case transcription(@Sendable (TMSMHome) -> any TranscriptionEngine)
    case speakers(@Sendable (TMSMHome) -> any SpeakerEngine)
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

  public var kind: Kind {
    switch factory {
    case .transcription: return .transcription
    case .speakers: return .speakers
    }
  }

  public init(
    id: String, name: String, engine: String, languages: [String], downloadMB: Int,
    license: String, gated: Bool, factory: Factory,
    storage: @escaping @Sendable (TMSMHome) -> [URL]
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
  }
}

/// A named pair of catalogue entries.
public struct Preset: Sendable, Equatable {
  public var name: String
  public var transcription: String
  public var speakers: String
  public var summary: String

  public init(name: String, transcription: String, speakers: String, summary: String) {
    self.name = name
    self.transcription = transcription
    self.speakers = speakers
    self.summary = summary
  }
}

/// What one engine contributes. Each engine folder under `Engines/` provides one.
public struct EngineRegistration: Sendable {
  public var engine: String
  public var entries: [CatalogueEntry]
  public var presets: [Preset]

  public init(engine: String, entries: [CatalogueEntry], presets: [Preset]) {
    self.engine = engine
    self.entries = entries
    self.presets = presets
  }
}

public struct Catalogue: Sendable {
  public static let defaultPreset = "default"
  /// Every engine tmsm ships. Session B appends the MLX registration here.
  public static let registrations: [EngineRegistration] = [FluidAudioEngine.registration]
  public static let shared = Catalogue(registrations)

  public let entries: [CatalogueEntry]
  public let presets: [Preset]

  public init(_ registrations: [EngineRegistration]) {
    entries = registrations.flatMap(\.entries)
    presets = registrations.flatMap(\.presets)
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
