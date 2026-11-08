import Foundation
import TMSM

// A tiny test runner: XCTest and Swift Testing need full Xcode; this needs only the CLT.
// Each session adds its cases in its own file (CoreCases, MLXCases, SetupCases) and lists them here.

final class Runner {
  var failures: [String] = []
  var checks = 0
  var current = ""

  func test(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { fail("threw \(error)") }
  }

  func expect<T: Equatable>(
    _ actual: T, _ expected: T, _ note: String = "", line: Int = #line
  ) {
    checks += 1
    if actual != expected {
      fail("\(note.isEmpty ? "" : note + ": ")expected \(expected), got \(actual) (line \(line))")
    }
  }

  func expect(_ condition: Bool, _ note: String, line: Int = #line) {
    checks += 1
    if !condition { fail("\(note) (line \(line))") }
  }

  func fail(_ message: String) {
    failures.append("\(current): \(message)")
  }
}

let runner = Runner()
CoreCases.run(runner)

if runner.failures.isEmpty {
  print("selftest: \(runner.checks) checks passed")
} else {
  for failure in runner.failures { print("FAIL \(failure)") }
  print("selftest: \(runner.failures.count) of \(runner.checks) checks failed")
  exit(1)
}
