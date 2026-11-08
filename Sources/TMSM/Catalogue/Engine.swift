import Foundation

/// A word with its time span in seconds.
public struct Word: Sendable, Equatable, Codable {
  public var text: String
  public var start: Double
  public var end: Double

  public init(_ text: String, _ start: Double, _ end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// A span where one speaker talks. Spans of different speakers may overlap.
/// `speaker` is the engine's own index; tmsm renumbers speakers by first appearance.
public struct SpeakerSegment: Sendable, Equatable, Codable {
  public var speaker: Int
  public var start: Double
  public var end: Double

  public init(_ speaker: Int, _ start: Double, _ end: Double) {
    self.speaker = speaker
    self.start = start
    self.end = end
  }
}

/// Per-frame speaker activity (probabilities 0...1), frame-major: `values[frame * speakers + s]`.
public struct SpeakerActivity: Sendable, Equatable {
  public var frameSeconds: Double
  public var speakers: Int
  public var values: [Float]

  public init(frameSeconds: Double, speakers: Int, values: [Float]) {
    self.frameSeconds = frameSeconds
    self.speakers = speakers
    self.values = values
  }

  public var frames: Int { speakers > 0 ? values.count / speakers : 0 }

  /// Summed activity of `speaker` over frames whose centre lies in `start..<end`, in seconds.
  public func mass(_ speaker: Int, _ start: Double, _ end: Double) -> Double {
    guard speaker >= 0, speaker < speakers, frames > 0 else { return 0 }
    let first = max(0, Int((start / frameSeconds - 0.5).rounded(.up)))
    let last = min(frames, Int((end / frameSeconds - 0.5).rounded(.up)))
    guard first < last else { return 0 }
    var sum = 0.0
    for f in first..<last { sum += Double(values[f * speakers + speaker]) }
    return sum * frameSeconds
  }
}

/// What a speaker engine returns: segments, and frame activity when the model has it.
public struct SpeakerTrack: Sendable, Equatable {
  public var segments: [SpeakerSegment]
  public var activity: SpeakerActivity?

  public init(segments: [SpeakerSegment], activity: SpeakerActivity? = nil) {
    self.segments = segments
    self.activity = activity
  }
}

/// 16 kHz mono samples.
public struct Audio: Sendable {
  public static let sampleRate = 16_000
  public var samples: [Float]
  public var duration: Double { Double(samples.count) / Double(Audio.sampleRate) }

  public init(samples: [Float]) {
    self.samples = samples
  }
}

/// Speech to text. An engine downloads and loads its model inside `transcribe` and releases it
/// before returning, so the pipeline can load models one after another.
public protocol TranscriptionEngine: Sendable {
  /// `language` is an ISO 639-1 code, or nil for automatic.
  func transcribe(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word]
}

/// Speaker labelling. Same lifecycle as `TranscriptionEngine`.
public protocol SpeakerEngine: Sendable {
  /// `maxSpeakers` is the most distinct speakers the caller will keep.
  func label(_ audio: Audio, maxSpeakers: Int, progress: Progress) async throws -> SpeakerTrack
}
