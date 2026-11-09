import Foundation

/// Cleans a speaker engine's segments before they drive decoding or assignment.
///
/// Diarizers mark every "mm-hm" and breath of a listener as a segment of its own. Those
/// fragments are right as speaker activity but wrong as turns: decoded alone they are too
/// short to carry speech, and in overlap they hand the talking speaker's words to the listener.
public enum SpeakerSegments {
  /// Same-speaker segments closer than this are one segment, in seconds.
  public static let mergeGap = 0.5
  /// A segment shorter than this is a fragment, in seconds…
  public static let shortSeconds = 1.0
  /// …and is absorbed when another speaker's longer segment overlaps it or lies within this
  /// gap of it, in seconds. A short reply nobody talks over stays a segment.
  public static let absorbGap = 0.3

  /// Merges each speaker's near-adjacent segments, then drops fragments another speaker talks
  /// over or around. Sorted by start; the speaker indices are kept.
  public static func clean(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
    let merged = mergeNeighbours(segments.filter { $0.end > $0.start })
    return merged.filter { s in
      guard s.end - s.start < shortSeconds else { return true }
      return !merged.contains { o in
        o.speaker != s.speaker && o.end - o.start > s.end - s.start
          && o.start - absorbGap < s.end && s.start - absorbGap < o.end
      }
    }
  }

  /// One segment per run of same-speaker segments closer than `mergeGap`.
  static func mergeNeighbours(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
    var result: [SpeakerSegment] = []
    let speakers = Set(segments.map(\.speaker)).sorted()
    for speaker in speakers {
      var merged: SpeakerSegment?
      for s in segments.filter({ $0.speaker == speaker }).sorted(by: { $0.start < $1.start }) {
        if var m = merged, s.start - m.end < mergeGap {
          m.end = max(m.end, s.end)
          merged = m
        } else {
          if let m = merged { result.append(m) }
          merged = s
        }
      }
      if let m = merged { result.append(m) }
    }
    return result.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
  }
}
