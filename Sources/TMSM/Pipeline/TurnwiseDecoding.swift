import Foundation

/// Turn-wise decoding: speakers are labelled first, the file is cut into speaker turns, and the
/// speech model transcribes each turn on its own. Every word takes its turn's speaker.
///
/// The turns cover the whole file, so no audio is dropped: stretches no speaker segment covers
/// go to the neighbouring turn (split at the middle between two different speakers).
public enum TurnwiseDecoding {
  /// One stretch of samples spoken by one speaker (engine index).
  public struct Piece: Sendable, Equatable {
    public var speaker: Int
    public var range: Range<Int>

    public init(speaker: Int, range: Range<Int>) {
      self.speaker = speaker
      self.range = range
    }
  }

  /// Frame length used to lay the speaker segments out on a timeline, in seconds.
  static let frameSeconds = 0.01
  /// Turns shorter than this are padded with silence before decoding, in seconds.
  public static let minimumSeconds = 1.0

  /// The file's turns, in order, covering `0..<sampleCount` without gaps or overlaps. Turns
  /// longer than `Chunking.targetSeconds` are split at quiet points.
  ///
  /// Where segments of two speakers overlap, the one who started more recently has the turn
  /// (someone talking over another takes over until they stop).
  public static func plan(
    segments: [SpeakerSegment], sampleCount: Int, maxSpeakers: Int,
    energy: (Range<Int>) -> Double
  ) -> [Piece] {
    guard sampleCount > 0 else { return [] }
    let kept = SpeakerAssignment.keepLongest(segments, max(1, maxSpeakers))
      .sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    let frameSamples = max(1, Int(frameSeconds * Double(Audio.sampleRate)))
    let frames = (sampleCount + frameSamples - 1) / frameSamples
    guard !kept.isEmpty else {
      return split(Piece(speaker: 0, range: 0..<sampleCount), energy: energy)
    }

    // Each frame's speaker: among the segments covering its centre, the latest to start.
    // Painting the segments in start order leaves exactly that.
    var label = [Int?](repeating: nil, count: frames)
    for seg in kept {
      let first = max(0, Int((seg.start / frameSeconds - 0.5).rounded(.up)))
      let last = min(frames, Int((seg.end / frameSeconds - 0.5).rounded(.up)))
      guard first < last else { continue }
      for f in first..<last { label[f] = seg.speaker }
    }

    // Runs of one label; unlabelled runs go to their neighbours.
    var runs: [(speaker: Int?, from: Int, to: Int)] = []
    for (f, s) in label.enumerated() {
      if let last = runs.last, last.speaker == s {
        runs[runs.count - 1].to = f + 1
      } else {
        runs.append((s, f, f + 1))
      }
    }
    var turns: [(speaker: Int, from: Int, to: Int)] = []
    for (i, run) in runs.enumerated() {
      if let s = run.speaker {
        if let last = turns.last, last.speaker == s {
          turns[turns.count - 1].to = run.to
        } else {
          turns.append((s, run.from, run.to))
        }
        continue
      }
      let before = i > 0 ? runs[i - 1].speaker : nil
      let after = i + 1 < runs.count ? runs[i + 1].speaker : nil
      switch (before, after) {
      case (nil, nil):
        turns.append((0, run.from, run.to))
      case (.some, nil):
        turns[turns.count - 1].to = run.to
      case (nil, let a?):
        turns.append((a, run.from, run.to))
      case (let b?, let a?):
        // A pause inside one speaker's talk stays in the turn.
        if a == b {
          turns[turns.count - 1].to = run.to
        } else {
          let middle = (run.from + run.to) / 2
          turns[turns.count - 1].to = middle
          turns.append((a, middle, run.to))
        }
      }
    }

    var pieces: [Piece] = []
    for turn in turns {
      let range =
        min(turn.from * frameSamples, sampleCount)..<min(turn.to * frameSamples, sampleCount)
      guard !range.isEmpty else { continue }
      if let last = pieces.last, last.speaker == turn.speaker,
        last.range.upperBound == range.lowerBound
      {
        pieces[pieces.count - 1].range = last.range.lowerBound..<range.upperBound
      } else {
        pieces.append(Piece(speaker: turn.speaker, range: range))
      }
    }
    return pieces.flatMap { split($0, energy: energy) }
  }

  /// A long turn → pieces of at most `Chunking.targetSeconds`, cut at quiet points.
  static func split(_ piece: Piece, energy: (Range<Int>) -> Double) -> [Piece] {
    let base = piece.range.lowerBound
    return Chunking.plan(sampleCount: piece.range.count) { r in
      energy((base + r.lowerBound)..<(base + r.upperBound))
    }.map { Piece(speaker: piece.speaker, range: (base + $0.lowerBound)..<(base + $0.upperBound)) }
  }

  /// Decodes every piece with one engine call; returns the words in file time and each word's
  /// speaker (engine index). Words a padded piece puts past its real end are clamped to it.
  public static func decode(
    _ audio: Audio, pieces: [Piece], engine: any TranscriptionEngine, language: String?,
    progress: Progress
  ) async throws -> (words: [Word], speakers: [Int]) {
    let minimum = Int(minimumSeconds * Double(Audio.sampleRate))
    let segments = pieces.map { piece -> Audio in
      var samples = Array(audio.samples[piece.range])
      if samples.count < minimum {
        samples += [Float](repeating: 0, count: minimum - samples.count)
      }
      return Audio(samples: samples)
    }
    let decoded = try await engine.transcribe(
      segments: segments, language: language, progress: progress)
    var words: [Word] = []
    var speakers: [Int] = []
    for (piece, pieceWords) in zip(pieces, decoded) {
      let offset = Double(piece.range.lowerBound) / Double(Audio.sampleRate)
      let length = Double(piece.range.count) / Double(Audio.sampleRate)
      for w in pieceWords {
        let start = min(max(w.start, 0), length)
        let end = min(max(w.end, start), length)
        words.append(Word(w.text, offset + start, offset + end))
        speakers.append(piece.speaker)
      }
    }
    return (words, speakers)
  }
}
