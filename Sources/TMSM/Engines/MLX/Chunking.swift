import Foundation

/// Cuts long audio into windows the MLX models decode in one pass.
///
/// Fixed-length windows, each cut at the quietest point near its end, so a cut rarely splits a
/// word and no audio is dropped. (A voice-activity segmenter was measured to lose far more
/// conversational speech on far-field meetings than fixed windows do.)
public enum Chunking {
  /// Longest window, in seconds. Qwen3-ASR decodes at most 448 tokens per call, which 25 s of
  /// fast speech stays well under.
  public static let targetSeconds = 25.0
  /// How far back from the window's end to look for a quiet cut, in seconds.
  public static let searchSeconds = 5.0
  /// Length of the energy window the quiet point is measured over, in seconds.
  public static let energySeconds = 0.1

  public static func plan(
    sampleCount: Int, sampleRate: Int = Audio.sampleRate,
    targetSeconds: Double = targetSeconds, searchSeconds: Double = searchSeconds,
    energy: (Range<Int>) -> Double
  ) -> [Range<Int>] {
    guard sampleCount > 0 else { return [] }
    let target = max(1, Int(targetSeconds * Double(sampleRate)))
    let search = min(target - 1, max(0, Int(searchSeconds * Double(sampleRate))))
    let window = max(1, Int(energySeconds * Double(sampleRate)))
    let step = max(1, window / 2)

    var ranges: [Range<Int>] = []
    var start = 0
    while sampleCount - start > target {
      let lo = start + target - search
      let hi = start + target
      var cut = hi
      var quietest = Double.infinity
      var w = lo
      while w + window <= hi {
        let e = energy(w..<(w + window))
        if e < quietest {
          quietest = e
          cut = w + window / 2
        }
        w += step
      }
      ranges.append(start..<cut)
      start = cut
    }
    ranges.append(start..<sampleCount)
    return ranges
  }

  /// Windows over real samples, using mean square energy.
  public static func plan(_ samples: [Float], sampleRate: Int = Audio.sampleRate) -> [Range<Int>] {
    plan(sampleCount: samples.count, sampleRate: sampleRate) { meanSquare(samples, $0) }
  }

  public static func meanSquare(_ samples: [Float], _ range: Range<Int>) -> Double {
    guard !range.isEmpty else { return 0 }
    var sum = 0.0
    for i in range { sum += Double(samples[i] * samples[i]) }
    return sum / Double(range.count)
  }

  /// Below this mean square (about -70 dBFS) a frame counts as silence.
  public static let silenceMeanSquare = 1e-7
  /// Frame length for the silence test, in seconds.
  public static let silenceFrameSeconds = 0.025

  /// True only when every 25 ms frame of the range is below the silence level. Such windows are
  /// not decoded (speech models tend to invent text for pure silence); a window with even one
  /// short quiet reply is.
  public static func isSilent(_ samples: [Float], _ range: Range<Int>) -> Bool {
    let frame = max(1, Int(silenceFrameSeconds * Double(Audio.sampleRate)))
    var start = range.lowerBound
    while start < range.upperBound {
      let end = min(start + frame, range.upperBound)
      if meanSquare(samples, start..<end) >= silenceMeanSquare { return false }
      start = end
    }
    return true
  }
}
