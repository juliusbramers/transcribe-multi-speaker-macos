import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import VoxtralASR

/// Speech to text on MLX: windows → text (Qwen3-ASR or Voxtral) → word timings (Qwen3 aligner).
///
/// The speech model and the aligner are loaded one after the other, never together, so a run's
/// peak memory is the larger of the two, not their sum. Each model loads once per run, however
/// many segments (whole file or speaker turns) it is given.
struct MLXTranscriber: TranscriptionEngine {
  let spec: MLXTranscriberSpec
  let home: TMSMHome

  /// Turn words are spread evenly over their window (no aligner), so they carry no times.
  var timesWords: Bool { false }

  /// One window to decode: a range of samples in one input segment.
  struct Piece {
    var segment: Int
    var range: Range<Int>
  }

  /// One file: words timed by the forced aligner.
  func transcribe(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word] {
    // speech-swift prints loading and alignment notes to stdout.
    try await MLXEngine.quiet {
      try await run([audio], language: language, align: true, progress: progress)
    }[0]
  }

  /// Speaker turns (or a language-detection sample): the words take their turn's speaker, so
  /// exact word times are not needed and the aligner is not loaded; words are spread evenly over
  /// their window.
  func transcribe(segments: [Audio], language: String?, progress: Progress) async throws
    -> [[Word]]
  {
    try await MLXEngine.quiet {
      try await run(segments, language: language, align: false, progress: progress)
    }
  }

  private func run(
    _ segments: [Audio], language: String?, align alignWords: Bool, progress: Progress
  ) async throws -> [[Word]] {
    let pieces = segments.enumerated().flatMap { i, audio in
      Chunking.plan(audio.samples).map { Piece(segment: i, range: $0) }
    }
    let (texts, used) = try await recognise(
      segments, pieces: pieces, language: language, progress: progress)
    Memory.clearCache()  // the speech model is gone; return its buffers before the aligner loads
    guard alignWords else {
      var words = [[Word]](repeating: [], count: segments.count)
      for (piece, text) in zip(pieces, texts) where !text.isEmpty {
        words[piece.segment] += WordTiming.words(
          [], text: text, offset: Double(piece.range.lowerBound) / Double(Audio.sampleRate),
          length: Double(piece.range.count) / Double(Audio.sampleRate))
      }
      return words
    }
    let words = try await align(
      segments, pieces: pieces, texts: texts, language: used, progress: progress)
    Memory.clearCache()
    return words
  }

  /// Text per piece ("" for silent ones), and the language it was decoded in. Loads the speech
  /// model once, decodes, releases it.
  func recognise(
    _ segments: [Audio], pieces: [Piece], language: String?, progress: Progress
  ) async throws -> ([String], String?) {
    MLXEngine.redirectCaches(home)
    let model = try await load(progress: progress)
    let speech = pieces.map { !Chunking.isSilent(segments[$0.segment].samples, $0.range) }
    func samples(_ piece: Piece) -> [Float] {
      WindowPadding.padded(segments[piece.segment].samples[piece.range])
    }

    // The language comes from the caller: the pipeline fixes it once per file (Qwen3 left to
    // detect it per window emits the wrong script on some). nil decodes unconditioned, which is
    // what language detection itself wants.
    let used = language
    progress.stage("Transcribing")
    var texts: [String] = []
    for (i, piece) in pieces.enumerated() {
      try Task.checkCancellation()
      texts.append(
        speech[i]
          ? try model(samples(piece), used).trimmingCharacters(in: .whitespacesAndNewlines) : "")
      progress.update(Double(i + 1) / Double(max(1, pieces.count)))
      await Task.yield()
    }
    return (texts, used)
  }

  /// Loads the speech model and returns a decoder (samples, language) that holds the only
  /// reference to it, so the model is freed when the caller drops the closure. Decoding is
  /// greedy: the same audio always gives the same text.
  private func load(progress: Progress) async throws -> ([Float], String?) throws -> String {
    switch spec.kind {
    case .qwen3:
      let model = try await MLXEngine.load(spec.model, home, progress) { dir in
        try await Qwen3ASRModel.fromPretrained(
          modelId: spec.model.repo, cacheDir: dir, offlineMode: true)
      }
      // speech-swift masks repeated trigrams on windows over 15 s unless told not to; that
      // rewrites natural repeats ("du möchtest … du möchtest" → "möchtes"), so it is off. A
      // decode that does loop is redone once with a mild repetition penalty.
      return { samples, language in
        var options = Qwen3DecodingOptions(
          language: language.flatMap(LanguageDetection.name), temperature: 0,
          longInputNoRepeatNgramSize: 0)
        let text = try model.transcribeThrowing(
          audio: samples, sampleRate: Audio.sampleRate, options: options)
        guard MLXTranscriber.loops(text) else { return text }
        options.repetitionPenalty = 1.1
        return try model.transcribeThrowing(
          audio: samples, sampleRate: Audio.sampleRate, options: options)
      }
    case .voxtral:
      let model = try await MLXEngine.load(spec.model, home, progress) { dir in
        try await VoxtralModel.fromPretrained(spec.model.repo, cacheDir: dir, offlineMode: true)
      }
      // Voxtral only decodes by argmax. Its default of 128 tokens can cut off a fast-spoken
      // 25 s window.
      return { samples, language in
        model.transcribe(
          audio: samples, sampleRate: Audio.sampleRate,
          options: VoxtralDecodingOptions(maxTokens: 448, language: language))
      }
    }
  }

  /// True when some run of one to three words repeats itself at least `loopRepeats` times in a
  /// row: a decoder stuck in a loop, not speech.
  static let loopRepeats = 4
  static func loops(_ text: String) -> Bool {
    let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    for n in 1...3 {
      guard words.count >= n * loopRepeats else { continue }
      for phase in 0..<n {
        var run = 1
        var i = phase + n
        while i + n <= words.count {
          if Array(words[i..<(i + n)]) == Array(words[(i - n)..<i]) {
            run += 1
            if run >= loopRepeats { return true }
          } else {
            run = 1
          }
          i += n
        }
      }
    }
    return false
  }

  /// Word timings for each piece's text, grouped by segment. Loads the aligner, aligns,
  /// releases it.
  func align(
    _ segments: [Audio], pieces: [Piece], texts: [String], language: String?,
    progress: Progress
  ) async throws -> [[Word]] {
    var result = [[Word]](repeating: [], count: segments.count)
    guard texts.contains(where: { !$0.isEmpty }) else { return result }
    MLXEngine.redirectCaches(home)
    let model = MLXEngine.aligner
    let aligner = try await MLXEngine.load(model, home, progress) { dir in
      try await Qwen3ForcedAligner.fromPretrained(
        modelId: model.repo, cacheDir: dir, offlineMode: true)
    }

    // The aligner splits words by language only for scripts without spaces.
    let languageName = language.flatMap(LanguageDetection.name) ?? "English"
    progress.stage("Aligning words")
    for (i, (piece, text)) in zip(pieces, texts).enumerated() where !text.isEmpty {
      try Task.checkCancellation()
      let samples = segments[piece.segment].samples[piece.range]
      let spans = WordTiming.alignWithRecovery(text: text, length: samples.count) {
        sub, from in
        let audio = WindowPadding.padded(samples.dropFirst(from))
        return aligner.align(
          audio: audio, text: String(sub), sampleRate: Audio.sampleRate, language: languageName
        ).map { ($0.text, Double($0.startTime), Double($0.endTime)) }
      }
      let offset = Double(piece.range.lowerBound) / Double(Audio.sampleRate)
      let length = Double(piece.range.count) / Double(Audio.sampleRate)
      result[piece.segment] += WordTiming.words(spans, text: text, offset: offset, length: length)
      progress.update(Double(i + 1) / Double(max(1, pieces.count)))
      await Task.yield()
    }
    progress.update(1)
    return result
  }
}

/// Turns aligner output into tmsm words.
///
/// Each aligned word is located in the recognised text, in order, so every word keeps its
/// original spelling and place: repeats the aligner produces cannot duplicate text, and text it
/// skips stays where it was, with times spread over the gap between its aligned neighbours.
enum WordTiming {
  /// An aligned stretch of the text, with times in seconds from the window's start.
  struct Span {
    var range: Range<String.Index>
    var start: Double
    var end: Double
  }

  /// How far ahead (in characters) an aligned word is looked for before it counts as unmatched.
  static let lookahead = 48
  /// Saturation: at least this many consecutive words stuck at one time…
  static let plateauWords = 5
  /// …within this many seconds of each other.
  static let plateauTolerance = 0.1

  /// Aligns `text` with bounded recovery: when the aligner's times saturate (a run of words
  /// stuck at one time), the reliable prefix is kept and the rest of the original text is
  /// aligned again on the rest of the audio, with the same text boundaries. `align` gets the
  /// remaining text and the sample offset to start from, and returns words with times relative
  /// to that offset.
  static func alignWithRecovery(
    text: String, length: Int, maxPasses: Int = 4,
    minimumSamples: Int = Audio.sampleRate,
    align: (Substring, Int) -> [(String, Double, Double)]
  ) -> [Span] {
    var spans: [Span] = []
    var textStart = text.startIndex
    var sampleStart = 0
    for _ in 0..<maxPasses {
      let rest = text[textStart...]
      guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
      let shift = Double(sampleStart) / Double(Audio.sampleRate)
      let aligned = align(rest, sampleStart).map { ($0.0, $0.1 + shift, $0.2 + shift) }
      let found = locate(aligned, in: text, from: textStart)
      guard let stuck = plateau(found) else {
        spans += found
        break
      }
      let reliable = found.prefix(stuck)
      spans += reliable
      guard let last = reliable.last else { break }
      let next = Int(last.end * Double(Audio.sampleRate))
      guard length - next >= minimumSamples, next > sampleStart else { break }
      textStart = last.range.upperBound
      sampleStart = next
    }
    return spans
  }

  /// Finds each aligned word in `text` from `from` on, in order, ignoring whitespace (the
  /// aligner folds lone punctuation into the word before it). A word not found within
  /// `lookahead` characters is dropped; the cursor never moves back.
  static func locate(
    _ aligned: [(String, Double, Double)], in text: String, from: String.Index
  ) -> [Span] {
    var spans: [Span] = []
    var cursor = from
    for (surface, start, end) in aligned {
      let wanted = Array(surface.filter { !$0.isWhitespace })
      guard !wanted.isEmpty else { continue }
      var candidate = cursor
      var tried = 0
      while candidate < text.endIndex, tried < lookahead {
        if !text[candidate].isWhitespace, let matchEnd = match(wanted, in: text, at: candidate) {
          spans.append(Span(range: candidate..<matchEnd, start: start, end: end))
          cursor = matchEnd
          break
        }
        candidate = text.index(after: candidate)
        tried += 1
      }
    }
    return spans
  }

  /// End of `wanted` matched at `start`, skipping whitespace in the text.
  private static func match(_ wanted: [Character], in text: String, at start: String.Index)
    -> String.Index?
  {
    var i = start
    var k = 0
    while k < wanted.count {
      guard i < text.endIndex else { return nil }
      if text[i].isWhitespace {
        i = text.index(after: i)
        continue
      }
      guard text[i] == wanted[k] else { return nil }
      i = text.index(after: i)
      k += 1
    }
    return i
  }

  /// Index of the first span of a saturated run, or nil when the times look healthy.
  static func plateau(_ spans: [Span]) -> Int? {
    guard spans.count >= plateauWords else { return nil }
    var runStart = 0
    for i in 1..<spans.count {
      if abs(spans[i].start - spans[runStart].start) > plateauTolerance { runStart = i }
      if i - runStart + 1 >= plateauWords { return runStart }
    }
    return nil
  }

  /// The text's words in order: aligned spans with their times, unaligned stretches split at
  /// whitespace with times spread over the gap between their neighbours. Times are clamped into
  /// `0...length`, never run backwards, and are shifted by `offset`.
  static func words(_ spans: [Span], text: String, offset: Double, length: Double) -> [Word] {
    var items: [(text: String, time: (Double, Double)?)] = []
    func addUnaligned(_ part: Substring) {
      for token in part.split(whereSeparator: \.isWhitespace) {
        items.append((String(token), nil))
      }
    }
    var cursor = text.startIndex
    var last = 0.0
    for span in spans {
      addUnaligned(text[cursor..<span.range.lowerBound])
      let start = min(max(span.start, last), length)
      let end = min(max(span.end, start), length)
      items.append((String(text[span.range]), (start, end)))
      last = start
      cursor = span.range.upperBound
    }
    addUnaligned(text[cursor...])

    var times = items.map(\.time)
    var i = 0
    while i < times.count {
      guard times[i] == nil else {
        i += 1
        continue
      }
      var k = i
      while k < times.count, times[k] == nil { k += 1 }
      let from = i > 0 ? times[i - 1]!.1 : 0
      let to = max(from, k < times.count ? times[k]!.0 : length)
      let step = (to - from) / Double(k - i)
      for n in i..<k { times[n] = (from + Double(n - i) * step, from + Double(n - i + 1) * step) }
      i = k
    }
    return zip(items, times).map { Word($0.text, offset + $1!.0, offset + $1!.1) }
  }
}

/// Models need a minimum of audio to make one encoder frame; shorter windows are padded with
/// silence (times are clamped to the real length afterwards).
enum WindowPadding {
  static let minimumSamples = Audio.sampleRate / 2

  static func padded(_ samples: ArraySlice<Float>) -> [Float] {
    var result = Array(samples)
    if result.count < minimumSamples {
      result += [Float](repeating: 0, count: minimumSamples - result.count)
    }
    return result
  }
}
