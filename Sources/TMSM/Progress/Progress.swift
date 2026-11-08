import Dispatch
import Foundation
import Synchronization

/// Progress on stderr.
///
/// - `bar`: a terminal. One line, redrawn in place: stage, bar, percent and time left.
///   Stages that can't be measured (compiling, labelling) show a spinner and the elapsed time.
/// - `lines`: no terminal. One plain line per stage, each stage name once per run.
/// - `quiet`: nothing.
public final class Progress: Sendable {
  public enum Mode: Sendable, Equatable { case bar, lines, quiet }

  public let mode: Mode
  private let sink: @Sendable (String) -> Void
  private let clock: @Sendable () -> Double
  private let state = Mutex(State())
  private let ticker = Mutex<DispatchSourceTimer?>(nil)

  private struct State {
    var stage: String?
    var fraction: Double?  // nil: activity
    var stageStart = 0.0
    var lastDraw = -1.0
    var frame = 0
    var drawn = false
    var printed: Set<String> = []  // lines mode: each stage once per run
  }

  public init(
    mode: Mode,
    sink: @escaping @Sendable (String) -> Void = Progress.stderr,
    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.mode = mode
    self.sink = sink
    self.clock = clock
  }

  /// The mode for this process: `quiet` wins, then a terminal on stderr gets the bar.
  public static func mode(quiet: Bool, isTerminal: Bool = isatty(STDERR_FILENO) == 1) -> Mode {
    if quiet { return .quiet }
    return isTerminal ? .bar : .lines
  }

  public static let stderr: @Sendable (String) -> Void = { text in
    FileHandle.standardError.write(Data(text.utf8))
  }

  public static let silent = Progress(mode: .quiet, sink: { _ in })

  /// A stage with a known size; follow with `update(_:)`.
  public func stage(_ name: String) { begin(name, fraction: 0) }

  /// A stage that can't be measured.
  public func activity(_ name: String) { begin(name, fraction: nil) }

  /// Fraction done in the current measurable stage, 0...1.
  public func update(_ fraction: Double) {
    guard mode == .bar else { return }
    let now = clock()
    let line: String? = state.withLock { s in
      guard s.stage != nil else { return nil }
      s.fraction = min(max(fraction, 0), 1)
      guard now - s.lastDraw >= 0.1 || s.fraction == 1 else { return nil }
      s.lastDraw = now
      s.drawn = true
      return Progress.render(s, now: now)
    }
    if let line { sink("\r\u{1B}[2K" + line) }
  }

  /// Clears the bar. Call once at the end, before anything else goes to stderr.
  public func finish() {
    stopTicker()
    let clear = state.withLock { s in
      defer { s = State() }
      return s.drawn
    }
    if mode == .bar && clear { sink("\r\u{1B}[2K") }
  }

  private func begin(_ name: String, fraction: Double?) {
    let now = clock()
    switch mode {
    case .quiet:
      return
    case .lines:
      let isNew = state.withLock { s in
        s.stage = name
        return s.printed.insert(name).inserted
      }
      if isNew { sink("tmsm: \(name)\n") }
    case .bar:
      let line: String? = state.withLock { s in
        // Repeating the current stage (download callbacks do) keeps its bar and clock.
        if s.stage == name && (s.fraction == nil) == (fraction == nil) { return nil }
        if s.stage != name { s.stageStart = now }
        s.stage = name
        s.fraction = fraction
        s.lastDraw = now
        s.drawn = true
        return Progress.render(s, now: now)
      }
      guard let line else { return }
      sink("\r\u{1B}[2K" + line)
      if fraction == nil { startTicker() } else { stopTicker() }
    }
  }

  private func tick() {
    let now = clock()
    let line: String? = state.withLock { s in
      guard s.stage != nil, s.fraction == nil else { return nil }
      s.frame += 1
      return Progress.render(s, now: now)
    }
    if let line { sink("\r\u{1B}[2K" + line) }
  }

  private func startTicker() {
    ticker.withLock { timer in
      guard timer == nil else { return }
      let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      source.schedule(deadline: .now() + 0.1, repeating: 0.1)
      source.setEventHandler { [weak self] in self?.tick() }
      source.resume()
      timer = source
    }
  }

  private func stopTicker() {
    ticker.withLock { timer in
      timer?.cancel()
      timer = nil
    }
  }

  private static func render(_ s: State, now: Double) -> String {
    let elapsed = now - s.stageStart
    if let fraction = s.fraction {
      return barLine(stage: s.stage ?? "", fraction: fraction, elapsed: elapsed)
    }
    return activityLine(stage: s.stage ?? "", frame: s.frame, elapsed: elapsed)
  }

  // MARK: Pure formatting, tested by selftest

  static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  public static func barLine(stage: String, fraction: Double, elapsed: Double, width: Int = 24)
    -> String
  {
    let f = min(max(fraction, 0), 1)
    let filled = Int((f * Double(width)).rounded(.down))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    var line = "\(stage)  \(bar) \(String(format: "%3d", Int((f * 100).rounded(.down))))%"
    if let left = remaining(fraction: f, elapsed: elapsed) {
      line += "  \(clockTime(left)) left"
    }
    return line
  }

  public static func activityLine(stage: String, frame: Int, elapsed: Double) -> String {
    "\(stage)  \(spinner[frame % spinner.count]) \(clockTime(elapsed))"
  }

  /// Time left, linear in the fraction done. Nil until 3% and 1 s in, when it means something.
  public static func remaining(fraction: Double, elapsed: Double) -> Double? {
    guard fraction >= 0.03, fraction < 1, elapsed >= 1 else { return nil }
    return elapsed * (1 - fraction) / fraction
  }

  /// m:ss, or h:mm:ss from one hour.
  public static func clockTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}
