import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import VoxtralASR

/// Speech to text on MLX: windows → text (Qwen3-ASR or Voxtral) → word timings (Qwen3 aligner).
///
/// The speech model and the aligner are loaded one after the other, never together, so a run's
/// peak memory is the larger of the two, not their sum.
struct MLXTranscriber: TranscriptionEngine {
  let spec: MLXTranscriberSpec
  let home: TMSMHome

  func transcribe(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word] {
    // speech-swift prints loading and alignment notes to stdout.
    try await MLXEngine.quiet { try await run(audio, language: language, progress: progress) }
  }

  private func run(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word] {
    let windows = Chunking.plan(audio.samples)
    let texts = try await recognise(audio, windows: windows, language: language, progress: progress)
    Memory.clearCache()  // the speech model is gone; return its buffers before the aligner loads
    let alignLanguage = language ?? LanguageDetection.language(of: texts.joined(separator: " "))
    let words = try await align(
      audio, windows: windows, texts: texts, language: alignLanguage, progress: progress)
    Memory.clearCache()
    return words
  }

  /// Text per window ("" for silent windows). Loads the speech model, decodes, releases it.
  func recognise(
    _ audio: Audio, windows: [Range<Int>], language: String?, progress: Progress
  ) async throws -> [String] {
    MLXEngine.redirectCaches(home)
    let decode = try await load(language: language, progress: progress)

    progress.stage("Transcribing")
    var texts: [String] = []
    for (i, window) in windows.enumerated() {
      try Task.checkCancellation()
      let samples = WindowPadding.padded(audio.samples[window])
      if Chunking.meanSquare(audio.samples, window) < Chunking.silenceMeanSquare {
        texts.append("")
      } else {
        texts.append(try decode(samples).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      progress.update(Double(i + 1) / Double(windows.count))
      await Task.yield()
    }
    return texts
  }

  /// Loads the speech model and returns a window decoder that holds the only reference to it,
  /// so the model is freed when the caller drops the closure.
  private func load(
    language: String?, progress: Progress
  ) async throws -> ([Float]) throws -> String {
    switch spec.kind {
    case .qwen3:
      // Offline: `MLXEngine.load` has just downloaded everything.
      let model = try await MLXEngine.load(spec.model, home, progress) { dir in
        try await Qwen3ASRModel.fromPretrained(
          modelId: spec.model.repo, cacheDir: dir, offlineMode: true)
      }
      // Greedy: the same audio always gives the same text.
      let options = Qwen3DecodingOptions(
        language: language.flatMap(LanguageDetection.name), temperature: 0)
      return { samples in
        try model.transcribeThrowing(audio: samples, sampleRate: Audio.sampleRate, options: options)
      }
    case .voxtral:
      let model = try await MLXEngine.load(spec.model, home, progress) { dir in
        try await VoxtralModel.fromPretrained(spec.model.repo, cacheDir: dir, offlineMode: true)
      }
      // Greedy (Voxtral only decodes by argmax). Its default of 128 tokens can cut off a
      // fast-spoken 25 s window.
      let options = VoxtralDecodingOptions(maxTokens: 448, language: language)
      return { samples in
        model.transcribe(audio: samples, sampleRate: Audio.sampleRate, options: options)
      }
    }
  }

  /// Word timings for each window's text. Loads the aligner, aligns, releases it.
  func align(
    _ audio: Audio, windows: [Range<Int>], texts: [String], language: String?,
    progress: Progress
  ) async throws -> [Word] {
    guard texts.contains(where: { !$0.isEmpty }) else { return [] }
    MLXEngine.redirectCaches(home)
    let model = MLXEngine.aligner
    let aligner = try await MLXEngine.load(model, home, progress) { dir in
      try await Qwen3ForcedAligner.fromPretrained(
        modelId: model.repo, cacheDir: dir, offlineMode: true)
    }

    // The aligner splits words by language only for scripts without spaces.
    let languageName = language.flatMap(LanguageDetection.name) ?? "English"
    progress.stage("Aligning words")
    var words: [Word] = []
    for (i, (window, text)) in zip(windows, texts).enumerated() where !text.isEmpty {
      try Task.checkCancellation()
      let offset = Double(window.lowerBound) / Double(Audio.sampleRate)
      let length = Double(window.count) / Double(Audio.sampleRate)
      let aligned = aligner.alignLong(
        audio: WindowPadding.padded(audio.samples[window]), text: text,
        sampleRate: Audio.sampleRate,
        language: languageName)
      words += WordTiming.place(
        aligned.map { ($0.text, Double($0.startTime), Double($0.endTime)) },
        text: text, offset: offset, length: length)
      progress.update(Double(i + 1) / Double(windows.count))
      await Task.yield()
    }
    progress.update(1)
    return words
  }
}

/// Turns aligner output into tmsm words.
enum WordTiming {
  /// The recognised text's words, with the aligner's times where it gave them, shifted to file
  /// time and clamped into the window.
  ///
  /// The aligner can return fewer words than the text holds (it stops when its timings
  /// saturate, or returns nothing). Words it missed keep their place and get times spread over
  /// the gap between their aligned neighbours, so no transcribed word is lost.
  static func place(
    _ aligned: [(text: String, start: Double, end: Double)], text: String, offset: Double,
    length: Double
  ) -> [Word] {
    let tokens = joinPunctuation(text.split(whereSeparator: \.isWhitespace).map(String.init))
    guard !tokens.isEmpty else { return [] }
    var timed: [(text: String, start: Double, end: Double)] = []
    var last = 0.0
    for word in aligned {
      let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let start = min(max(word.start, last), length)
      timed.append((trimmed, start, min(max(word.end, start), length)))
      last = start
    }
    // More aligned words than spaces: a script without spaces, which the aligner splits itself.
    if timed.count > tokens.count {
      return unspaced(timed, text: text, offset: offset, length: length)
    }

    // Match text words to aligned words in order; the aligner may skip one now and then.
    var times = [(start: Double, end: Double)?](repeating: nil, count: tokens.count)
    var j = 0
    for (i, token) in tokens.enumerated() where j < timed.count {
      let key = normalise(token)
      if let k = (j..<min(j + 3, timed.count)).first(where: { normalise(timed[$0].text) == key }) {
        times[i] = (timed[k].start, timed[k].end)
        j = k + 1
      }
    }
    // Spread unmatched runs over the gap between their neighbours.
    var i = 0
    while i < tokens.count {
      guard times[i] == nil else {
        i += 1
        continue
      }
      var k = i
      while k < tokens.count, times[k] == nil { k += 1 }
      let from = i > 0 ? times[i - 1]!.end : 0
      let to = max(from, k < tokens.count ? times[k]!.start : length)
      let step = (to - from) / Double(k - i)
      for n in i..<k {
        times[n] = (from + Double(n - i) * step, from + Double(n - i + 1) * step)
      }
      i = k
    }
    return zip(tokens, times).map { Word($0, offset + $1!.start, offset + $1!.end) }
  }

  /// Unspaced scripts: the aligner's words, plus any tail of the text it did not reach as one
  /// word at the end of the window.
  private static func unspaced(
    _ timed: [(text: String, start: Double, end: Double)], text: String, offset: Double,
    length: Double
  ) -> [Word] {
    var words = timed.map { Word($0.text, offset + $0.start, offset + $0.end) }
    let covered = timed.map(\.text).joined().filter { !$0.isWhitespace }.count
    let all = text.filter { !$0.isWhitespace }
    if covered < all.count {
      let start = timed.last?.end ?? 0
      words.append(Word(String(all.dropFirst(covered)), offset + start, offset + length))
    }
    return words
  }

  /// Punctuation-only tokens ("—", "…") join the word before them, as the aligner does.
  static func joinPunctuation(_ tokens: [String]) -> [String] {
    var result: [String] = []
    for token in tokens {
      if normalise(token).isEmpty, !result.isEmpty {
        result[result.count - 1] += " " + token
      } else {
        result.append(token)
      }
    }
    return result
  }

  /// Letters and digits only, lowercased: how the aligner's words and the text's are compared.
  static func normalise(_ word: String) -> String {
    String(
      word.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(
        Character.init))
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
