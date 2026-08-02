/// `trial --self-test-metrics`: a battery of hand-computed, scripted-
/// sequence checks against `TrialMetrics.swift`'s pure functions, runnable
/// with no camera or audio device — the CLI-target-native substitute for a
/// dedicated `aboutface-cliTests` target, which does not exist in
/// `Package.swift` (only `AboutFaceCoreTests` does; adding a second test
/// target is a build-graph change out of scope for an additive CLI
/// subcommand). Every expected value below is computed by hand in the doc
/// comments, not by re-running the same algorithm, so this genuinely
/// exercises the arithmetic rather than checking the code against itself.
///
/// Coverage: `ConvergenceTracker` (entry/settle timing, path integral,
/// per-axis overshoot counting, settle-window steadiness), `TrialStats`
/// (median/mean/stddev/aggregate), `DisplacementCheck`,
/// `TrialSessionStore.configHash`'s determinism, a `TrialSessionLog` JSON
/// round-trip, and the end-of-session summary/comparison sentence builders.
/// NOT covered here (documented, not silently skipped): the live
/// camera/audio integration loop in `TrialCommand.swift` / `TrialProtocol.
/// swift` itself — that has no headless equivalent (§14's own rule: never
/// require a live camera in CI) and needs the maintainer's live run to
/// verify by ear.
///
/// Split across three files purely to keep each one within SwiftLint's
/// default size limits, the same reasoning `AnalysisEngine`'s own file
/// split uses: this file (the `Failure` type and `run()`'s dispatch list),
/// `TrialSelfTestChecks.swift` (the actual scripted checks), and
/// `TrialSelfTestAssertions.swift` (the tiny `expect(...)` helpers).
enum TrialSelfTest {
  struct Failure {
    let name: String
    let detail: String
  }

  /// Runs every check; returns the failures (empty = full pass). Printing
  /// and exit-code decisions are the caller's job (`Trial.runSelfTest`).
  static func run() -> [Failure] {
    var failures: [Failure] = []
    checkConvergenceTracker(&failures)
    checkTrialStats(&failures)
    checkDisplacementCheck(&failures)
    checkConfigHash(&failures)
    checkSessionLogRoundTrip(&failures)
    checkSessionSummary(&failures)
    return failures
  }
}
