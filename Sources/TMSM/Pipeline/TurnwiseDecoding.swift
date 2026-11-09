import Foundation

/// Turn-wise decoding: speakers are labelled first, the file is cut into speaker turns, and the
/// speech model transcribes each turn on its own, with a little of the neighbouring audio for
/// context. Every word takes its turn's speaker.
///
/// The turns cover the whole file, so no audio is dropped: stretches no speaker segment covers
/// go to the neighbouring turn (split at the middle between two different speakers).
public enum TurnwiseDecoding {
  /// One stretch of samples spoken by one speaker (engine index). `range` is the turn itself;
  /// `padded` adds context on both sides and is what the model hears. Words are kept by where
  /// their middle falls, so each word lands in exactly one turn.
  public struct Piece: Sendable, Equatable {
    public var speaker: Int
    public var range: Range<Int>
    public var padded: Range<Int>

    public init(speaker: Int, range: Range<Int>, padded: Range<Int>? = nil) {
      self.speaker = speaker
      self.range = range
      self.padded = padded ?? range
    }
  }

  /// Frame length used to lay the speaker segments out on a timeline, in seconds.
  static let frameSeconds = 0.01
  /// Turns shorter than this are padded with silence before decoding, in seconds.
  public static let minimumSeconds = 1.0
  /// Audio added before and after a turn so the model hears how it begins and ends, in
  /// seconds. Half a word cut off at a turn boundary is otherwise read as a word of its own.
  public static let contextSeconds = 0.3
  /// A cut between two speakers moves to the quietest `Chunking.energySeconds` within this
  /// distance, in seconds, so it does not fall inside a word…
  public static let snapSeconds = 0.3
  /// …but only to a point at most this share as loud as the original cut; otherwise there is
  /// no pause to move to and the cut stays.
  public static let snapGain = 0.5

  /// The file's turns, in order, covering `0..<sampleCount` without gaps or overlaps. Turns
  /// longer than `Chunking.targetSeconds` are split at quiet points.
  ///
  /// Segments are cleaned first (see `SpeakerSegments`). Where segments of two speakers
  /// overlap, the one whose segment is longer has the turn: a listener's interjection does not
  /// take the words of the one talking.
  public static func plan(
    segments: [SpeakerSegment], sampleCount: Int, maxSpeakers: Int,
    energy: (Range<Int>) -> Double
  ) -> [Piece] {
    guard sampleCount > 0 else { return [] }
    let kept = SpeakerSegments.clean(SpeakerAssignment.keepLongest(segments, max(1, maxSpeakers)))
    let frameSamples = max(1, Int(frameSeconds * Double(Audio.sampleRate)))
    let frames = (sampleCount + frameSamples - 1) / frameSamples
    guard !kept.isEmpty else {
      return split(Piece(speaker: 0, range: 0..<sampleCount), energy: energy)
        .map { pad($0, sampleCount: sampleCount) }
    }

    // Each frame's speaker: among the segments covering its centre, the longest. Painting the
    // segments shortest first leaves exactly that.
    var label = [Int?](repeating: nil, count: frames)
    for seg in kept.sorted(by: { ($0.end - $0.start, $0.speaker) < ($1.end - $1.start, $1.speaker) }
    ) {
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

    // Sample ranges, with every cut between two speakers moved to the nearest quiet point.
    var cuts = turns.dropFirst().map { min($0.from * frameSamples, sampleCount) }
    let snap = Int(snapSeconds * Double(Audio.sampleRate))
    var previous = 0
    for i in cuts.indices {
      let lo = max(previous + 1, cuts[i] - snap)
      let hi = min(sampleCount - 1, cuts[i] + snap)
      if lo < hi { cuts[i] = quietest(lo..<hi, origin: cuts[i], energy: energy) }
      cuts[i] = max(previous, min(cuts[i], sampleCount))
      previous = cuts[i]
    }
    var pieces: [Piece] = []
    var start = 0
    for (i, turn) in turns.enumerated() {
      let end = i < cuts.count ? cuts[i] : sampleCount
      let range = start..<end
      start = end
      guard !range.isEmpty else { continue }
      if let last = pieces.last, last.speaker == turn.speaker {
        pieces[pieces.count - 1].range = last.range.lowerBound..<range.upperBound
      } else {
        pieces.append(Piece(speaker: turn.speaker, range: range))
      }
    }
    return pieces.flatMap { split($0, energy: energy) }.map { pad($0, sampleCount: sampleCount) }
  }

  /// The centre of the quietest `Chunking.energySeconds` window inside `range` when it is at
  /// most `snapGain` as loud as the window at `origin`; otherwise `origin`. Among equally quiet
  /// windows, the nearest to `origin`.
  static func quietest(_ range: Range<Int>, origin: Int, energy: (Range<Int>) -> Double) -> Int {
    let window = max(1, Int(Chunking.energySeconds * Double(Audio.sampleRate)))
    guard range.count > window else { return origin }
    let at = max(range.lowerBound, min(origin - window / 2, range.upperBound - window))
    let original = energy(at..<(at + window))
    var best = origin
    var quietest = Double.infinity
    var w = range.lowerBound
    while w + window <= range.upperBound {
      let e = energy(w..<(w + window))
      let centre = w + window / 2
      if e < quietest || (e == quietest && abs(centre - origin) < abs(best - origin)) {
        quietest = e
        best = centre
      }
      w += max(1, window / 2)
    }
    return quietest <= snapGain * original ? best : origin
  }

  /// A long turn → pieces of at most `Chunking.targetSeconds`, cut at quiet points.
  static func split(_ piece: Piece, energy: (Range<Int>) -> Double) -> [Piece] {
    let base = piece.range.lowerBound
    return Chunking.plan(sampleCount: piece.range.count) { r in
      energy((base + r.lowerBound)..<(base + r.upperBound))
    }.map { Piece(speaker: piece.speaker, range: (base + $0.lowerBound)..<(base + $0.upperBound)) }
  }

  /// The piece with `contextSeconds` of audio added on both sides, inside the file.
  static func pad(_ piece: Piece, sampleCount: Int) -> Piece {
    let context = Int(contextSeconds * Double(Audio.sampleRate))
    var p = piece
    p.padded =
      max(0, piece.range.lowerBound - context)..<min(sampleCount, piece.range.upperBound + context)
    return p
  }

  /// Decodes every piece with one engine call; returns the words in file time and each word's
  /// speaker (engine index). An engine that times its words hears the padded piece, and a word
  /// belongs to the piece its middle falls in; one that does not hears the bare turn and every
  /// word is kept. Times are clamped into the piece.
  ///
  /// Two neighbouring pieces both hear the audio around their cut, so a word there can come
  /// out of both decodes with slightly different times. After the middle rule, each cut is
  /// reconciled: the same word accepted on both sides is kept once (where it lies deeper
  /// inside its piece), and a word both sides pushed across the cut is kept by the side that
  /// heard it first.
  public static func decode(
    _ audio: Audio, pieces: [Piece], engine: any TranscriptionEngine, language: String?,
    progress: Progress
  ) async throws -> (words: [Word], speakers: [Int]) {
    let minimum = Int(minimumSeconds * Double(Audio.sampleRate))
    let timed = engine.timesWords
    let pieces = timed ? pieces : pieces.map { Piece(speaker: $0.speaker, range: $0.range) }
    let segments = pieces.map { piece -> Audio in
      var samples = Array(audio.samples[piece.padded])
      if samples.count < minimum {
        samples += [Float](repeating: 0, count: minimum - samples.count)
      }
      return Audio(samples: samples)
    }
    let decoded = try await engine.transcribe(
      segments: segments, language: language, progress: progress)
    let rate = Double(Audio.sampleRate)

    // Per piece: the words it owns, and the words it heard but whose middle lies past a cut.
    var owned: [[Word]] = []
    var spilled: [[Word]] = []
    for (piece, pieceWords) in zip(pieces, decoded) {
      let offset = Double(piece.padded.lowerBound) / rate
      let from = Double(piece.range.lowerBound) / rate
      let to = Double(piece.range.upperBound) / rate
      let isFirst = piece.range.lowerBound == 0
      let isLast = piece.range.upperBound == audio.samples.count
      var mine: [Word] = []
      var spill: [Word] = []
      for w in pieceWords {
        let start = offset + max(w.start, 0)
        let end = offset + max(w.end, max(w.start, 0))
        let middle = (start + end) / 2
        // Untimed engines heard only the turn: every word is theirs. The first piece keeps
        // what lies before it, the last what lies after.
        let inside = !timed || (middle >= from || isFirst) && (middle < to || isLast)
        if inside {
          mine.append(Word(w.text, start, end))
        } else {
          spill.append(Word(w.text, start, end))
        }
      }
      owned.append(mine)
      spilled.append(spill)
    }

    if timed {
      for i in pieces.indices.dropLast() {
        let cut = Double(pieces[i].range.upperBound) / rate
        let near = contextSeconds * 2
        // The same word accepted on both sides of the cut: keep the deeper copy.
        for (k, right) in owned[i + 1].enumerated() where right.start < cut + near {
          guard
            let j = owned[i].lastIndex(where: {
              $0.end > cut - near && same($0.text, right.text)
            })
          else { continue }
          let left = owned[i][j]
          if cut - (left.start + left.end) / 2 >= (right.start + right.end) / 2 - cut {
            owned[i + 1].remove(at: k)
          } else {
            owned[i].remove(at: j)
          }
          break
        }
        // A word both sides heard but neither kept: the left side keeps it.
        for w in spilled[i] where (w.start + w.end) / 2 < cut + near {
          let keptRight = owned[i + 1].contains { $0.start < cut + near && same($0.text, w.text) }
          let keptLeft = owned[i].contains { $0.end > cut - near && same($0.text, w.text) }
          if !keptRight && !keptLeft { owned[i].append(w) }
        }
      }
    }

    var words: [Word] = []
    var speakers: [Int] = []
    for (piece, mine) in zip(pieces, owned) {
      let from = Double(piece.range.lowerBound) / rate
      let to = Double(piece.range.upperBound) / rate
      for w in mine.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
        let s = min(max(w.start, from), to)
        words.append(Word(w.text, s, min(max(w.end, s), to)))
        speakers.append(piece.speaker)
      }
    }
    return (words, speakers)
  }

  /// The same word, ignoring case and punctuation.
  static func same(_ a: String, _ b: String) -> Bool {
    func key(_ s: String) -> String {
      String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    let ka = key(a)
    return !ka.isEmpty && ka == key(b)
  }
}
