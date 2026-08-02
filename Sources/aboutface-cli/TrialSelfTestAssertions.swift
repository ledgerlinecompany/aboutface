import Foundation

/// Tiny hand-rolled assertion helpers for `TrialSelfTest` — deliberately
/// NOT `assert(...)`/`precondition(...)`, since those no-op in a
/// `-Ounchecked`/release build; these always run and always collect a
/// `Failure` rather than trapping, so `trial --self-test-metrics` reports
/// every failing check in one pass instead of stopping at the first one.
extension TrialSelfTest {
  static func expect(
    _ actual: String, contains substring: String, name: String, failures: inout [Failure]
  ) {
    guard actual.contains(substring) else {
      failures.append(
        Failure(name: name, detail: "expected to find \"\(substring)\" in \"\(actual)\""))
      return
    }
  }

  static func expect(
    _ actual: Double?, equals expected: Double?, name: String, tolerance: Double = 1e-9,
    failures: inout [Failure]
  ) {
    switch (actual, expected) {
    case (nil, nil):
      return
    case (let actual?, let expected?) where abs(actual - expected) <= tolerance:
      return
    default:
      let detail = "expected \(String(describing: expected)), got \(String(describing: actual))"
      failures.append(Failure(name: name, detail: detail))
    }
  }

  static func expect(
    _ actual: Int, equalsInt expected: Int, name: String, failures: inout [Failure]
  ) {
    guard actual == expected else {
      failures.append(Failure(name: name, detail: "expected \(expected), got \(actual)"))
      return
    }
  }

  static func expect(
    _ actual: Int?, equalsInt expected: Int, name: String, failures: inout [Failure]
  ) {
    guard let actual else {
      failures.append(Failure(name: name, detail: "expected \(expected), got nil"))
      return
    }
    expect(actual, equalsInt: expected, name: name, failures: &failures)
  }

  static func expect(
    _ actual: Bool, equalsBool expected: Bool, name: String, failures: inout [Failure]
  ) {
    guard actual == expected else {
      failures.append(Failure(name: name, detail: "expected \(expected), got \(actual)"))
      return
    }
  }
}
