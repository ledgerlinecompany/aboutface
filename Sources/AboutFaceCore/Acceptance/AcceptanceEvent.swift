/// §13 Phase 4's acceptance instrument: "a 30-minute session with the user
/// leaving the desk for 10 minutes produces the correct
/// escalate-then-stop-then-recover sequence and nothing else." This file
/// defines the timestamped-event model a recorder (CLI-side —
/// `aboutface-cli acceptance`) produces and `AcceptanceEvaluator` consumes.
/// Deliberately just a value type: nothing here touches `FeedbackRouter`,
/// `AudioRendering`, or `SpeechRendering` directly, so it can be built and
/// asserted against in a plain unit test with no I/O, no `AVCaptureDevice`,
/// and no real clock.
///
/// ## Why one flat event stream, not three
///
/// §7.3's ladder is only legible as a single ordered timeline: rung 2's
/// spoken "No face." has to be checked against rung 1's earcon, and rung 3's
/// silent `userLikelyAway` transition has to be checked against both. A
/// recorder that kept three separate logs (audio events, spoken phrases,
/// `userLikelyAway` samples) would push that interleaving problem onto every
/// caller. `AcceptanceEvent.Kind` merges the three channels the PR brief
/// names into one `Equatable` sum type instead, so `AcceptanceEvaluator` can
/// walk a single chronological sequence.
public struct AcceptanceEvent: Sendable, Equatable {
  /// What was observed. Three cases, one per channel `aboutface-cli
  /// acceptance` instruments (see that command's own doc comment):
  /// discrete `AudioEvent`s via `EventSubscriber` (§6.4), spoken
  /// `Lexicon.Phrase`s via a `SpeechRendering` logging decorator (neither
  /// protocol is changed to carry this — see `EventSubscriber.swift`'s own
  /// doc comment on why it is deliberately narrower than this), and
  /// `FeedbackRouter.isUserLikelyAway()` transitions via polling (§7.3's
  /// rung 3 fires no sound at all, so this is the ONLY channel that can ever
  /// see it).
  public enum Kind: Sendable, Equatable {
    case audioEvent(AudioEvent)
    case spokenPhrase(Lexicon.Phrase)
    /// The NEW value `isUserLikelyAway()` was observed to hold — a
    /// recorder only ever appends one of these on a value CHANGE (true→false
    /// or false→true), never one per poll tick, so this stream already
    /// reads as "transitions," not "samples." See `AcceptanceEvaluator`'s
    /// doc comment for why that distinction matters to rung 3's matching.
    case userLikelyAway(Bool)
  }

  /// Milliseconds elapsed since the recording session started (an explicit
  /// `ContinuousClock.Instant` captured once by the recorder) — the same
  /// "time is injected, always" discipline `FeedbackRouter` documents on
  /// itself (`FeedbackRouter.swift`'s type-level doc comment), applied here
  /// so `AcceptanceEvaluator` reads no clock of its own and a hand-built
  /// test fixture is exactly as meaningful as a real 30-minute recording.
  public let elapsedMs: Int
  public let kind: Kind

  public init(elapsedMs: Int, kind: Kind) {
    self.elapsedMs = elapsedMs
    self.kind = kind
  }

  /// §6.1's liveness heartbeat, which `AcceptanceEvaluator` reports as its
  /// own category rather than as one of the "everything else that fired"
  /// entries. Measured on a real 2-minute run (2026-08-06): six heartbeats
  /// across roughly forty seconds of presence, i.e. on the order of 170 in
  /// the 30-minute session §13 actually asks for. Left in the unexplained
  /// list they would bury the handful of entries that clause exists to
  /// expose, and a list nobody can read is worth what no list is worth.
  ///
  /// Separating them costs no rigor: a heartbeat inside the STOP window is
  /// still caught by `AcceptanceReport.strayRendererActivityDuringStop`,
  /// which is computed before this split and is where a heartbeat would be
  /// genuinely damning (§7.3 demands total silence there).
  public var isLivenessHeartbeat: Bool {
    kind == .audioEvent(.livenessHeartbeat)
  }
}
