/// `AcceptanceEvaluator.evaluate(_:)`'s output. Deliberately NOT a bare
/// pass/fail boolean (PR brief: "an automated verdict that says PASS while
/// hiding a stray event would be exactly the silent-plausible-value failure
/// this codebase has shipped three times") — every field here is either the
/// full observed timeline or an explanation a human reads and judges, never
/// a computed verdict this type asserts on the caller's behalf.
public struct AcceptanceReport: Sendable, Equatable {
  /// §7.3's ladder, in canonical order — the four markers a correct
  /// escalate-then-stop-then-recover episode produces. Always exactly four
  /// entries, one per `Rung` case, in this fixed order, whether or not each
  /// one was actually found.
  public enum Rung: String, Sendable, CaseIterable {
    /// §7.3 rung 1: `AudioEvent.faceLost`, after the mode's earcon delay.
    case earcon
    /// §7.3 rung 2: spoken `Lexicon.Instruction.noFace`, ~5s in.
    case spokenNoFace
    /// §7.3 rung 3: `userLikelyAway` becomes `true`, ~30s in. Fires no
    /// sound — see `AcceptanceEvent.Kind.userLikelyAway`'s doc comment.
    case stop
    /// `AudioEvent.faceReacquired` on return. Has no fixed schedule (it
    /// fires whenever the user actually comes back), so unlike the other
    /// three rungs this one is never timing-checked against a `Config`
    /// delay — only presence, order, and "exactly once."
    case recovery
  }

  /// One rung's result. `matched` is `true` only when the expected event
  /// was found, in the correct chronological position relative to the
  /// rungs before it, AND (for the three timed rungs) within
  /// `AcceptanceTolerances.rungTimingToleranceMs` of its `Config`-derived
  /// expected time. A rung that fired but badly off-schedule, or fired out
  /// of order, is reported as `matched: false` with `observedElapsedMs`
  /// still populated and `note` explaining exactly what was wrong — never
  /// silently folded into either "matched" or "missing" without an
  /// explanation a human can read.
  public struct RungResult: Sendable, Equatable {
    public let rung: Rung
    public let matched: Bool
    /// `nil` only when the rung was never found at all (in the correct
    /// chronological slot — see `AcceptanceEvaluator`'s doc comment on why
    /// an out-of-order occurrence does not count as "found" for THIS rung).
    public let observedElapsedMs: Int?
    /// `nil` for `.recovery` (no fixed schedule) and for the three timed
    /// rungs when the evaluator had no reference point to compute an
    /// expected time from at all (e.g. `.spokenNoFace`/`.stop` when
    /// `.earcon` itself was never found and no explicit episode start was
    /// given — see `AcceptanceEvaluator.Input.episodeStartMs`).
    public let expectedElapsedMs: Int?
    public let toleranceMs: Int?
    /// Always non-empty: what happened, in plain language, for the human
    /// reading this at a terminal — "found at 1520ms, expected 1500ms ±
    /// 250ms: OK", "missing", "found at 1800ms but out of order (occurred
    /// before rung `spokenNoFace`'s 5010ms) — not accepted", etc.
    public let note: String

    public init(
      rung: Rung, matched: Bool, observedElapsedMs: Int?, expectedElapsedMs: Int?,
      toleranceMs: Int?, note: String
    ) {
      self.rung = rung
      self.matched = matched
      self.observedElapsedMs = observedElapsedMs
      self.expectedElapsedMs = expectedElapsedMs
      self.toleranceMs = toleranceMs
      self.note = note
    }
  }

  /// Always exactly four entries, in `Rung.allCases` order.
  public let rungs: [RungResult]

  /// EVERY recorded event not consumed as one of the four rungs above —
  /// the "and nothing else" clause, and the part of §13 Phase 4's
  /// acceptance criterion a human cannot check by ear across half an hour
  /// (PR brief). Near-unfiltered: an event that is obviously benign (e.g.
  /// the `userLikelyAway(false)` transition that clears rung 3 on recovery)
  /// still appears here rather than being silently reclassified as
  /// "expected" — hiding an explainable event is worse than a human having
  /// to dismiss a few obviously-fine lines.
  ///
  /// The ONE exception is §6.1's liveness heartbeat, moved to `heartbeats`
  /// below. That is not a softening of the rule but an application of it: a
  /// 30-minute run puts ~170 heartbeats here, and a list that long stops
  /// being read at all, which would defeat the clause far more completely
  /// than reclassifying one well-understood periodic event ever could.
  public let unexplainedEvents: [AcceptanceEvent]

  /// §6.1's liveness heartbeats, split out of `unexplainedEvents` so that
  /// list stays readable — see `AcceptanceEvent.isLivenessHeartbeat` for the
  /// measurement that forced the split. Reported as its own category rather
  /// than discarded: the heartbeat is what distinguishes "good" from "the app
  /// crashed," so its COUNT and cadence are themselves worth seeing, and a
  /// run with zero of them across a long placed stretch would be a finding.
  public let heartbeats: [AcceptanceEvent]

  /// Face-lost episodes that never reached §7.3's rung-3 STOP. Expected in
  /// any real session — the maintainer's 30-minute acceptance run contained
  /// NINE (leaning out of frame, looking away, settling back into the chair)
  /// alongside the one deliberate absence. Reported as their own category so
  /// they are neither mistaken for the escalating episode nor buried in
  /// `unexplainedEvents`; see `AcceptanceEpisodeSegmenter`.
  public let nonEscalatingEpisodes: [AcceptanceEpisode]

  /// How many episodes DID escalate. Exactly one is the expected shape.
  /// Zero means the STOP never happened — a genuine acceptance failure, not
  /// a missing rung to shrug at. More than one means the session contained
  /// several long absences, and the report says which one it judged (the
  /// first).
  public let escalatedEpisodeCount: Int

  /// `AudioEvent.enteredGoodZone` firings outside the escalated episode —
  /// the ordinary arrival chime each time the user re-settles. Ten of them
  /// in the real 30-minute run, all legitimate. Split out for the same
  /// reason as `heartbeats`: they are expected, and leaving them in
  /// `unexplainedEvents` makes the one list a human must read unreadable.
  public let routineGoodZoneEntries: [AcceptanceEvent]

  /// The subset of `unexplainedEvents` that are audio/speech RENDERER
  /// activity (not `userLikelyAway` samples, which are silent bookkeeping,
  /// not sound) falling strictly between rung 3's observed time and
  /// recovery's observed time. §7.3: "Once `faceLostRung` reaches 3 ...
  /// nothing left to do on any later frame" — ANY entry in this list is
  /// evidence the STOP was not actually silent, which is the single most
  /// safety-critical claim this whole instrument exists to check. Empty
  /// when rung 3 was never found (nothing to bound the window with) —
  /// see `AcceptanceEvaluator.evaluate(_:)` for exactly how the window's
  /// open end is handled when recovery was never found either.
  public let strayRendererActivityDuringStop: [AcceptanceEvent]

  /// The onset `AcceptanceEvaluator` used as its reference point for rungs
  /// 2 and 3's expected timing, in elapsed ms. `nil` only when no reference
  /// point could be established at all (rung 1 missing and no explicit
  /// `episodeStartMs` given).
  public let referenceEpisodeStartMs: Int?

  /// `true` when `referenceEpisodeStartMs` was RECONSTRUCTED (rung 1's
  /// observed time minus its configured delay) rather than directly
  /// supplied by the caller. This instrument does not — cannot — directly
  /// observe the moment the user actually left the desk; a reconstructed
  /// start is an inference, not a measurement, and the report says so
  /// explicitly rather than presenting it with the same confidence as a
  /// caller-supplied one (PR brief: "honest about what it did not
  /// observe").
  public let referenceEpisodeStartIsInferred: Bool

  public init(
    rungs: [RungResult], unexplainedEvents: [AcceptanceEvent],
    heartbeats: [AcceptanceEvent] = [],
    nonEscalatingEpisodes: [AcceptanceEpisode] = [],
    escalatedEpisodeCount: Int = 0,
    routineGoodZoneEntries: [AcceptanceEvent] = [],
    strayRendererActivityDuringStop: [AcceptanceEvent], referenceEpisodeStartMs: Int?,
    referenceEpisodeStartIsInferred: Bool
  ) {
    self.rungs = rungs
    self.unexplainedEvents = unexplainedEvents
    self.heartbeats = heartbeats
    self.nonEscalatingEpisodes = nonEscalatingEpisodes
    self.escalatedEpisodeCount = escalatedEpisodeCount
    self.routineGoodZoneEntries = routineGoodZoneEntries
    self.strayRendererActivityDuringStop = strayRendererActivityDuringStop
    self.referenceEpisodeStartMs = referenceEpisodeStartMs
    self.referenceEpisodeStartIsInferred = referenceEpisodeStartIsInferred
  }
}
