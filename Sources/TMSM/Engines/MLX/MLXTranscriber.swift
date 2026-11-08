import AudioCommon
import CohereTranscribeASR
import Foundation
import MLX
import Qwen3ASR

/// Speech to text on MLX: windows → text (Qwen3-ASR or Cohere) → word timings (Qwen3 aligner).
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
      let samples = Array(audio.samples[window])
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
      let options = Qwen3DecodingOptions(language: language.flatMap(LanguageDetection.name))
      return { samples in
        try model.transcribeThrowing(audio: samples, sampleRate: Audio.sampleRate, options: options)
      }
    case .cohere:
      guard let language else {
        throw TMSMError.engine("\(spec.model.name) needs a language: pass --language")
      }
      let model = try await MLXEngine.load(spec.model, home, progress) { dir in
        try await CohereTranscribeModel.fromPretrained(
          spec.model.repo, cacheDir: dir, offlineMode: true)
      }
      // Longer than any window, so Cohere decodes each window in one piece.
      let options = CohereTranscribeDecodingOptions(
        language: language, chunkDuration: Chunking.targetSeconds + 5)
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
        audio: Array(audio.samples[window]), text: text, sampleRate: Audio.sampleRate,
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
  /// Clamps aligned words into their window and shifts them to file time. When the aligner
  /// returns nothing for a non-empty text, the text's words are spread evenly over the window,
  /// so no transcribed word is lost.
  static func place(
    _ aligned: [(text: String, start: Double, end: Double)], text: String, offset: Double,
    length: Double
  ) -> [Word] {
    var result: [Word] = []
    if aligned.isEmpty {
      let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
      guard !tokens.isEmpty else { return [] }
      let step = length / Double(tokens.count)
      for (i, token) in tokens.enumerated() {
        result.append(Word(token, offset + Double(i) * step, offset + Double(i + 1) * step))
      }
      return result
    }
    var last = 0.0
    for word in aligned {
      let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let start = min(max(word.start, last), length)
      let end = min(max(word.end, start), length)
      result.append(Word(trimmed, offset + start, offset + end))
      last = start
    }
    return result
  }
}
