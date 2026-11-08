import Darwin
import Foundation

/// Where setup, install and uninstall talk to a person. Everything goes to stderr: stdout is
/// reserved for results an agent can parse.
public protocol Console: AnyObject {
  /// A person can answer: stdin and stderr are both terminals.
  var isInteractive: Bool { get }
  func say(_ text: String)
  /// One line of input, or nil at end of input.
  func ask(_ prompt: String) -> String?
  /// Like `ask`, without echoing what is typed.
  func askHidden(_ prompt: String) -> String?
}

extension Console {
  /// Yes/no with a default; anything but y/yes/n/no keeps the default.
  public func confirm(_ question: String, default yes: Bool) -> Bool {
    let answer = ask("\(question) [\(yes ? "Y/n" : "y/N")] ")?
      .trimmingCharacters(in: .whitespaces).lowercased()
    switch answer {
    case "y", "yes": return true
    case "n", "no": return false
    default: return yes
    }
  }

  /// A number from 1...count; empty input picks `defaultIndex`. Asks again on anything else.
  public func choose(_ prompt: String, count: Int, defaultIndex: Int) -> Int? {
    while true {
      guard let line = ask("\(prompt) [\(defaultIndex + 1)]: ") else { return nil }
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.isEmpty { return defaultIndex }
      if let n = Int(text), (1...count).contains(n) { return n - 1 }
      say("Type a number from 1 to \(count).")
    }
  }
}

public final class TerminalConsole: Console {
  public let isInteractive: Bool

  public init(isInteractive: Bool = TerminalConsole.hasTerminal) {
    self.isInteractive = isInteractive
  }

  public static var hasTerminal: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }

  public func say(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  public func ask(_ prompt: String) -> String? {
    FileHandle.standardError.write(Data(prompt.utf8))
    return readLine()
  }

  public func askHidden(_ prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
      return nil
    }
    defer { for i in buffer.indices { buffer[i] = 0 } }  // the token does not linger
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
