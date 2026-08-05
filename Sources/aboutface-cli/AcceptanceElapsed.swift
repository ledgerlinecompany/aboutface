/// Shared `ContinuousClock.Instant` → elapsed-time conversion for every
/// `aboutface-cli acceptance` instrumentation type (`AcceptanceEventRecorder`,
/// `AcceptanceResourceSampler`) that needs to timestamp an observation
/// relative to one shared session start. A single small `enum` namespace
/// rather than each caller re-deriving its own, so the millisecond
/// arithmetic used to build an `AcceptanceEvent`/`AcceptanceResourceSample`
/// is identical everywhere it appears in a report.
///
/// Duplicates `FeedbackRouter.milliseconds(from:to:)`'s exact integer
/// arithmetic (that method is `internal` to `AboutFaceCore`, not visible
/// from this separate module) rather than widening its access purely for
/// this CLI target — see that method's own doc comment for why whole
/// attoseconds-based integer division is used instead of a floating-point
/// `Duration` conversion for the millisecond form.
enum AcceptanceElapsed {
  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant)
    -> Int
  {
    // swiftlint:enable opening_brace
    let (seconds, attoseconds) = (end - start).components
    return Int(seconds * 1000) + Int(attoseconds / 1_000_000_000_000_000)
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  /// Fractional seconds — used where a divisor needs to stay a `Double`
  /// (e.g. `AcceptanceResourceSampler`'s CPU-percent-per-interval math)
  /// rather than round-tripping through whole milliseconds.
  static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant)
    -> Double
  {
    // swiftlint:enable opening_brace
    let components = (end - start).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
