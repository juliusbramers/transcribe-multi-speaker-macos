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
      out += "\nSpeaker \(turn.speaker): \(Transcript.escapeText(turn.text))\n"
    }
    return out
  }

  /// A file name is plain text in a heading: one line, and every character that could start
  /// Markdown or HTML (links, emphasis, code, closing #s, entities) escaped. Dots, dashes and
  /// parentheses on their own change nothing and stay as they are.
  public static func escapeHeading(_ s: String) -> String {
    escape(oneLine(s), Set("\\`*_{}[]<>#!|~&"))
  }

  /// Recognised speech is shown as written: only what would change rendering is escaped (HTML,
  /// code, links), and anything that would start a block at the beginning of a line. Commas,
  /// periods, apostrophes and the like stay readable.
  public static func escapeText(_ s: String) -> String {
    var text = escape(oneLine(s), Set("\\`<[]"))
    // A turn follows "Speaker N: ", so these only matter if a line ever starts with them.
    if let first = text.first, "#>-*+".contains(first) { text = "\\" + text }
    if let dot = text.firstIndex(where: { !$0.isNumber }), dot != text.startIndex,
      text[dot] == "." || text[dot] == ")"
    {
      text.insert("\\", at: dot)
    }
    return text
  }

  static func oneLine(_ s: String) -> String {
    s.components(separatedBy: .newlines).joined(separator: " ")
  }

  static func escape(_ s: String, _ special: Set<Character>) -> String {
    var out = ""
    for c in s {
      if special.contains(c) { out.append("\\") }
      out.append(c)
    }
    return out
  }
}
