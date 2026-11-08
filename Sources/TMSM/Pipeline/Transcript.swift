import Foundation

/// Consecutive words of one speaker.
public struct Turn: Sendable, Equatable, Codable {
  public var speaker: Int
  public var text: String
  public var start: Double
  public var end: Double

  public init(speaker: Int, text: String, start: Double, end: Double) {
    self.speaker = speaker
    self.text = text
    self.start = start
    self.end = end
  }
}

public struct Transcript: Sendable, Equatable {
  public var title: String
  public var turns: [Turn]

  public init(title: String, turns: [Turn]) {
    self.title = title
    self.turns = turns
  }

  /// Joins words with their speakers (as from `SpeakerAssignment.assign`) into turns.
  public init(title: String, words: [Word], speakers: [Int]) {
    precondition(words.count == speakers.count)
    var turns: [Turn] = []
    for (word, speaker) in zip(words, speakers) {
      let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if var last = turns.last, last.speaker == speaker {
        last.text += " " + text
        last.end = word.end
        turns[turns.count - 1] = last
      } else {
        turns.append(Turn(speaker: speaker, text: text, start: word.start, end: word.end))
      }
    }
    self.init(title: title, turns: turns)
  }

  public var speakerCount: Int { Set(turns.map(\.speaker)).count }

  /// `# title`, then one `Speaker N: …` paragraph per turn. No timestamps.
  public var markdown: String {
    var out = "# \(Transcript.escapeHeading(title))\n"
    if turns.isEmpty {
      out += "\n_No speech found._\n"
    }
    for turn in turns {
      out += "\nSpeaker \(turn.speaker): \(turn.text)\n"
    }
    return out
  }

  /// A file name is plain text in a heading: keep it on one line.
  static func escapeHeading(_ s: String) -> String {
    s.components(separatedBy: .newlines).joined(separator: " ")
  }
}
