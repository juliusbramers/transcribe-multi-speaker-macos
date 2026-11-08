import Foundation
import MLX
import MossTranscribe

/// MOSS-Transcribe-Diarize on MLX: one decoder hears the whole recording and writes the words
/// with timestamps and anonymous speaker labels. Its context holds the entire file, so long
/// recordings cost memory that grows with their length; `MossPolicy` keeps that inside the
/// budget and says when the model should not be used.
struct MossTranscriber: JointEngine {
  let model: MLXModel
  let home: TMSMHome

  func transcribe(_ audio: Audio, language: String?, maxSpeakers: Int, progress: Progress)
    async throws -> JointResult
  {
    guard let options = MossPolicy.options(duration: audio.duration) else {
      return JointResult(words: [], speakers: [], segments: [], complete: false)
    }
    let result = try await decode(audio, options: options, progress: progress)
    // Not complete when the decoder was cut off, wrote no segments for audible audio, or
    // skipped audible speech on the way.
    guard result.complete,
      !result.words.isEmpty || Chunking.isSilent(audio.samples, 0..<audio.samples.count),
      MossTranscriber.coversSpeech(result.segments, of: audio)
    else {
      return JointResult(
        words: result.words, speakers: result.speakers, segments: result.segments,
        complete: false)
    }
    return result
  }

  private func decode(_ audio: Audio, options: MossMLXDecodingOptions, progress: Progress)
    async throws -> JointResult
  {
    MLXEngine.redirectCaches(home)
    let moss = try await MLXEngine.load(model, home, progress) { dir in
      try await MossMLXModel.fromDirectory(dir, modelId: model.repo)
    }
    // The decoder reports nothing while it runs: an activity line, not a bar.
    progress.activity("Transcribing with \(model.name)")
    let result: MossTranscription
    do {
      result = try await MLXEngine.quiet([STDOUT_FILENO, STDERR_FILENO]) {
        try moss.transcribeDetailed(
          audio: audio.samples, sampleRate: Audio.sampleRate, options: options)
      }
    }
    Memory.clearCache()
    return MossTranscriber.result(result, duration: audio.duration)
  }

  /// The model's segments as words with their speaker. A segment's words are spread evenly over
  /// its span (the model times segments, not words). Complete only when the decoder stopped on
  /// its own and the segments reach the end of the audio.
  static func result(_ transcription: MossTranscription, duration: Double) -> JointResult {
    var words: [Word] = []
    var speakers: [Int] = []
    var segments: [SpeakerSegment] = []
    var index: [String: Int] = [:]
    var reached = 0.0
    for segment in transcription.segments {
      let start = min(max(segment.startTime, 0), duration)
      let end = min(max(segment.endTime, start), duration)
      reached = max(reached, end)
      let speaker = index[segment.speaker] ?? index.count
      index[segment.speaker] = speaker
      if end > start { segments.append(SpeakerSegment(speaker, start, end)) }
      let tokens = segment.text.split(whereSeparator: \.isWhitespace)
      guard !tokens.isEmpty else { continue }
      let step = (end - start) / Double(tokens.count)
      for (i, token) in tokens.enumerated() {
        let s = start + Double(i) * step
        words.append(Word(String(token), s, s + step))
        speakers.append(speaker)
      }
    }
    let stopped = transcription.metrics.stopReason == .endOfSequence
    let complete = stopped && (words.isEmpty || duration - reached < MossPolicy.tailSeconds)
    return JointResult(words: words, speakers: speakers, segments: segments, complete: complete)
  }

  /// False when a stretch of at least `MossPolicy.gapSeconds` between (or before, or after)
  /// the segments holds audible sound: the model skipped speech there.
  static func coversSpeech(_ segments: [SpeakerSegment], of audio: Audio) -> Bool {
    let rate = Double(Audio.sampleRate)
    var cursor = 0.0
    let spans =
      segments.sorted { $0.start < $1.start }.map { ($0.start, $0.end) } + [
        (audio.duration, audio.duration)
      ]
    for (start, end) in spans {
      if start - cursor >= MossPolicy.gapSeconds {
        let range = Int(cursor * rate)..<Int(start * rate)
        if !range.isEmpty, !Chunking.isSilent(audio.samples, range) { return false }
      }
      cursor = max(cursor, end)
    }
    return true
  }
}

/// How MOSS is run for a recording of a given length, and when it is not.
///
/// The key/value cache grows with the audio (12.5 audio tokens per second) and the transcript.
/// Measured on a 38-minute two-speaker recording: 9.6 GB peak with the fp16 cache. Beyond
/// `fp16MaxSeconds` the cache is stored in int8, beyond `maxSeconds` the model is skipped and
/// the pipeline falls back to the next route.
enum MossPolicy {
  /// The decoder's context: audio tokens, prompt and output together.
  static let contextTokens = 131_072
  static let promptTokens = 1024
  /// Audio tokens per second of audio (the model's adaptor).
  static let audioTokensPerSecond = 12.5
  /// Generated tokens allowed per second of audio: German conversation measured about 7
  /// (words, punctuation, time marks and speaker tags); 10 leaves room for dense speech.
  static let outputTokensPerSecond = 10.0
  static let minimumTokens = 2048
  /// Longest recording decoded with an fp16 cache, in seconds (45 min: about 60 000 tokens,
  /// 6.9 GB of cache at 114 688 bytes per token, about 12 GB in all).
  static let fp16MaxSeconds = 45.0 * 60
  /// Longest recording MOSS decodes at all, in seconds (90 min: about 123 000 tokens, which
  /// fits the context, about 7 GB of int8 cache, about 12 GB in all).
  static let maxSeconds = 90.0 * 60
  /// A transcript whose last segment ends more than this before the audio does is incomplete.
  static let tailSeconds = 60.0
  /// Audible audio of at least this length with no segment means the model skipped speech.
  static let gapSeconds = 45.0

  /// Tokens the decoder may generate for `duration` seconds, or nil when the recording is too
  /// long for the context or the memory budget.
  static func outputTokens(duration: Double) -> Int? {
    guard duration <= maxSeconds else { return nil }
    let wanted = max(minimumTokens, Int(duration * outputTokensPerSecond))
    let room = contextTokens - promptTokens - Int(duration * audioTokensPerSecond)
    guard room >= minimumTokens else { return nil }
    return min(wanted, room)
  }

  static func options(duration: Double) -> MossMLXDecodingOptions? {
    guard let maxTokens = outputTokens(duration: duration) else { return nil }
    return MossMLXDecodingOptions(
      maxTokens: maxTokens, kvCachePrecision: duration <= fp16MaxSeconds ? .float16 : .int8)
  }
}
