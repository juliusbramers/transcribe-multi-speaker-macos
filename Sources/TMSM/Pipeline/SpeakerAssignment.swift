import Foundation

/// Gives each word one speaker.
///
/// 1. Speakers beyond `maxSpeakers` are dropped: the ones with the least total speech go first
///    (ties: the higher engine index goes).
/// 2. A word goes to the speaker whose segments overlap it the longest. With frame activity,
///    the speakers whose segments overlap the word are the candidates and the one with the most
///    activity over the word wins; overlapping speech at turn changes is common, and the
///    activity tells the stronger voice apart where binary overlap ties.
/// 3. A word no segment touches goes to the nearest segment if that is at most `maxGap`
///    seconds away.
/// 4. Anything still open takes the previous word's speaker; leading words take the first
///    assigned speaker.
/// 5. A lone short word (under `islandMaxWord` s) between two words of one other speaker, with
///    pauses of at most `islandMaxPause` s on both sides, joins them. The diarizer often marks a
///    brief untranscribed "mhm" there, and the word it lands on belongs to the flowing sentence.
///    Longer words such as a real "Genau." keep their speaker.
///
/// Ties in steps 2 and 3 go to the previous word's speaker if it is among them, otherwise to
/// the lowest engine index, so the result never depends on input order.
/// The returned speakers are numbered 1, 2, … in order of first appearance.
public enum SpeakerAssignment {
  public static let defaultMaxGap = 1.0
  /// Words shorter than this count as this long, so zero-length words still overlap.
  static let minWordSpan = 0.02
  public static let islandMaxWord = 0.35
  public static let islandMaxPause = 0.25

  public static func assign(
    words: [Word], segments: [SpeakerSegment], activity: SpeakerActivity? = nil,
    maxSpeakers: Int, maxGap: Double = defaultMaxGap
  ) -> [Int] {
    guard !words.isEmpty else { return [] }
    let kept = keepLongest(segments, max(1, maxSpeakers))
    var raw = [Int?](repeating: nil, count: words.count)
    var previous: Int?

    for (i, word) in words.enumerated() {
      let start = word.start
      let end = max(word.end, word.start + minWordSpan)

      var overlap: [Int: Double] = [:]
      for seg in kept {
        let o = min(end, seg.end) - max(start, seg.start)
        if o > 0 { overlap[seg.speaker, default: 0] += o }
      }
      if let activity, overlap.count > 1 {
        for s in overlap.keys { overlap[s] = activity.mass(s, start, end) }
      }
      var choice = pick(overlap, prefer: previous, larger: true)

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
    var speakers = raw.map { $0 ?? firstAssigned }

    // One left-to-right pass over the original labels, so results don't cascade.
    let before = speakers
    for i in words.indices.dropFirst().dropLast() {
      let (a, w, b) = (words[i - 1], words[i], words[i + 1])
      if before[i - 1] == before[i + 1], before[i] != before[i - 1],
        w.end - w.start < islandMaxWord, w.start - a.end <= islandMaxPause,
        b.start - w.end <= islandMaxPause
      {
        speakers[i] = before[i - 1]
      }
    }
    return renumber(speakers)
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
