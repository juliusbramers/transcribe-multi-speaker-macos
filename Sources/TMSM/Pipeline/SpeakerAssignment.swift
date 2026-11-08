import Foundation

/// Gives each word one speaker.
///
/// 1. Speakers beyond `maxSpeakers` are dropped: the ones with the least total speech go first
///    (ties: the higher engine index goes).
/// 2. A word goes to the speaker whose segments overlap it the longest. When several overlap it
///    about equally (within `nearTie` of the word's length) and the engine gives frame activity,
///    the most active of those wins: turn changes are often marked for both speakers at once.
///    Callers pass segments cleaned by `SpeakerSegments`, so a listener's "mm-hm" over the one
///    talking is no longer a segment that could take their words.
/// 3. A word no segment touches goes to the nearest segment if that is at most `maxGap`
///    seconds away.
/// 4. Anything still open takes the previous word's speaker; leading words take the first
///    assigned speaker.
/// 5. A short run of at most `islandMaxWords` words, under `islandMaxSpan` seconds, with pauses
///    of at most `islandMaxPause` seconds on both sides, between two runs of one other speaker
///    joins them, but only when that other speaker's segments also overlap it. A short reply
///    nobody else overlaps, or one set apart by a pause, keeps its speaker.
///
/// Remaining ties go to the previous word's speaker if it is among them, otherwise to the lowest
/// engine index, so the result never depends on input order.
/// The returned speakers are numbered 1, 2, … in order of first appearance.
public enum SpeakerAssignment {
  public static let defaultMaxGap = 1.0
  /// Words shorter than this count as this long, so zero-length words still overlap.
  static let minWordSpan = 0.02
  public static let nearTie = 0.2
  public static let islandMaxWords = 2
  public static let islandMaxSpan = 0.6
  public static let islandMaxPause = 0.5

  public static func assign(
    words: [Word], segments: [SpeakerSegment], activity: SpeakerActivity? = nil,
    maxSpeakers: Int, maxGap: Double = defaultMaxGap
  ) -> [Int] {
    guard !words.isEmpty else { return [] }
    let kept = keepLongest(segments, max(1, maxSpeakers))
    var raw = [Int?](repeating: nil, count: words.count)
    var overlaps = [[Int: Double]](repeating: [:], count: words.count)
    var previous: Int?

    for (i, word) in words.enumerated() {
      let start = word.start
      let end = max(word.end, word.start + minWordSpan)

      var overlap: [Int: Double] = [:]
      for seg in kept {
        let o = min(end, seg.end) - max(start, seg.start)
        if o > 0 { overlap[seg.speaker, default: 0] += o }
      }
      overlaps[i] = overlap

      var scores = overlap
      if let activity, let best = overlap.values.max() {
        let close = overlap.filter { best - $0.value <= nearTie * (end - start) }
        if close.count > 1 {
          scores = close.mapValues { _ in 0 }
          for s in close.keys { scores[s] = activity.mass(s, start, end) }
        }
      }
      var choice = pick(scores, prefer: previous, larger: true)

      if choice == nil {
        var distance: [Int: Double] = [:]
        for seg in kept {
          let d = seg.end <= start ? start - seg.end : seg.start - end
          guard d <= maxGap else { continue }
          distance[seg.speaker] = min(distance[seg.speaker] ?? .infinity, d)
        }
        choice = pick(distance, prefer: previous, larger: false)
      }

      raw[i] = choice ?? previous
      if let c = raw[i] { previous = c }
    }

    // Only leading words can still be open: after the first assignment `previous` is set.
    let firstAssigned = raw.compactMap { $0 }.first ?? 0
    let speakers = raw.map { $0 ?? firstAssigned }
    return renumber(smoothIslands(words: words, speakers: speakers, overlaps: overlaps))
  }

  /// One left-to-right pass over the original labels, so results don't cascade: a short run
  /// of one speaker inside another speaker's flow joins that flow when the flowing speaker's
  /// segments overlap at least one of its words.
  static func smoothIslands(words: [Word], speakers: [Int], overlaps: [[Int: Double]]) -> [Int] {
    var runs: [(speaker: Int, from: Int, to: Int)] = []
    for (i, s) in speakers.enumerated() {
      if let last = runs.last, last.speaker == s {
        runs[runs.count - 1].to = i + 1
      } else {
        runs.append((s, i, i + 1))
      }
    }
    var result = speakers
    for k in runs.indices.dropFirst().dropLast() {
      let run = runs[k]
      let around = runs[k - 1].speaker
      guard around == runs[k + 1].speaker, run.to - run.from <= islandMaxWords,
        words[run.to - 1].end - words[run.from].start < islandMaxSpan,
        words[run.from].start - words[run.from - 1].end <= islandMaxPause,
        words[run.to].start - words[run.to - 1].end <= islandMaxPause,
        (run.from..<run.to).contains(where: { (overlaps[$0][around] ?? 0) > 0 })
      else { continue }
      for i in run.from..<run.to { result[i] = around }
    }
    return result
  }

  /// Best key by value; exact ties go to `prefer`, then to the lowest key.
  static func pick(_ scores: [Int: Double], prefer: Int?, larger: Bool) -> Int? {
    guard let best = larger ? scores.values.max() : scores.values.min() else { return nil }
    let tied = scores.filter { abs($0.value - best) < 1e-9 }.map(\.key)
    if let prefer, tied.contains(prefer) { return prefer }
    return tied.min()
  }

  static func keepLongest(_ segments: [SpeakerSegment], _ count: Int) -> [SpeakerSegment] {
    var total: [Int: Double] = [:]
    for seg in segments where seg.end > seg.start {
      total[seg.speaker, default: 0] += seg.end - seg.start
    }
    guard total.count > count else { return segments.filter { $0.end > $0.start } }
    let keep = Set(
      total.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(count).map(\.key))
    return segments.filter { keep.contains($0.speaker) && $0.end > $0.start }
  }

  /// At most `count` speakers (0 keeps them all): the ones with the fewest words go, and each
  /// of their words takes the previous word's speaker (the first kept speaker for leading ones).
  public static func cap(_ speakers: [Int], _ count: Int) -> [Int] {
    guard count > 0 else { return speakers }
    var total: [Int: Int] = [:]
    for s in speakers { total[s, default: 0] += 1 }
    guard total.count > count else { return speakers }
    let keep = Set(
      total.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(count).map(\.key))
    let first = speakers.first { keep.contains($0) } ?? 0
    var previous = first
    return speakers.map { s in
      if keep.contains(s) { previous = s }
      return previous
    }
  }

  /// Engine indices → 1, 2, … by first appearance.
  public static func renumber(_ speakers: [Int]) -> [Int] {
    var map: [Int: Int] = [:]
    return speakers.map { s in
      if let n = map[s] { return n }
      let n = map.count + 1
      map[s] = n
      return n
    }
  }
}
