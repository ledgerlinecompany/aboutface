import Testing

@testable import AboutFaceCore

/// The maintainer's ACTUAL 30-minute §13 Phase 4 acceptance session
/// (2026-08-06), transcribed from its JSON log, minus the 98 heartbeats.
///
/// This fixture exists because that run **passed** and the evaluator scored
/// three of its four rungs as failures. The app did exactly what §7.3
/// specifies — earcon, "No face." at +5.0s, STOP at +30.4s, then 11.8 minutes
/// of total silence, then one recovery — and the report said "OFF SCHEDULE by
/// +255060ms" twice and called the single recovery a duplicate.
///
/// The cause was an assumption, not a bug in any one line: the evaluator
/// matched each rung by first eligible occurrence, which silently assumed a
/// session contains ONE face-lost episode. This one contained ten. Nine were
/// a second or two — leaning out of frame, looking away, settling back into
/// the chair — and the first of them, 57 seconds in, is what the ladder
/// anchored on.
///
/// An instrument that reports a false negative on a passing run is exactly as
/// useless as one that reports a false pass: either way its verdict cannot be
/// acted on. Every assertion below is a property of a real recording rather
/// than of a fixture designed to be convenient, which is the whole reason to
/// keep it.
struct AcceptanceRealSessionTests {
  /// The real timeline. Heartbeats are omitted (98 of them, every ~7s while
  /// placed) — they are covered by `AcceptanceEvaluatorTests` and would only
  /// obscure the shape here.
  private static var events: [AcceptanceEvent] {
    [
      AcceptanceEvent(elapsedMs: 0, kind: .userLikelyAway(false)),
      AcceptanceEvent(elapsedMs: 7218, kind: .audioEvent(.enteredGoodZone)),
      // Blip one: two seconds, 57s in. THIS is what the old evaluator
      // mistook for the start of the acceptance ladder.
      AcceptanceEvent(elapsedMs: 57326, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 59189, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 61066, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 135_968, kind: .audioEvent(.enteredGoodZone)),
      // The deliberate absence.
      AcceptanceEvent(elapsedMs: 312_440, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 315_886, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 341_281, kind: .userLikelyAway(true)),
      // ~11.8 minutes of nothing at all, then one recovery. "Right." is
      // §7.3's "or the problem, if there is one" branch.
      AcceptanceEvent(elapsedMs: 1_048_414, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 1_048_414, kind: .spokenPhrase(Lexicon.Instruction.right)),
      AcceptanceEvent(elapsedMs: 1_048_839, kind: .userLikelyAway(false)),
      // Settling back into the chair.
      AcceptanceEvent(elapsedMs: 1_050_807, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 1_051_092, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 1_058_281, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_333_643, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_366_168, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_550_890, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_571_961, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 1_574_087, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 1_577_554, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_657_522, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 1_680_170, kind: .audioEvent(.enteredGoodZone)),
    ]  // swiftlint:disable:previous trailing_comma
  }

  private static func report() -> AcceptanceReport {
    AcceptanceEvaluator.evaluate(
      AcceptanceEvaluator.Input(
        events: events, feedbackConfig: .defaults, mode: .monitor,
        tolerances: AcceptanceTolerances.derived(from: .defaults, awayPollIntervalMs: 1000)))
  }

  @Test("The real 30-minute session scores as passing: all four rungs match")
  func realSessionPasses() {
    let report = Self.report()
    for result in report.rungs {
      #expect(result.matched, "\(result.rung): \(result.note)")
    }
  }

  @Test("The ladder anchors on the deliberate absence, not the 57s blip")
  func anchorsOnEscalatedEpisode() {
    let report = Self.report()
    let byRung = Dictionary(uniqueKeysWithValues: report.rungs.map { ($0.rung, $0) })
    #expect(byRung[.earcon]?.observedElapsedMs == 312_440)
    #expect(byRung[.spokenNoFace]?.observedElapsedMs == 315_886)
    #expect(byRung[.stop]?.observedElapsedMs == 341_281)
    #expect(byRung[.recovery]?.observedElapsedMs == 1_048_414)
  }

  /// The safety-critical claim: §7.3's silence has to be as reliable as its
  /// alerts. Nothing sounded across the 11.8 minutes between the STOP and the
  /// recovery.
  @Test("The STOP was genuinely silent for the whole absence")
  func stopWasSilent() {
    #expect(Self.report().strayRendererActivityDuringStop.isEmpty)
  }

  @Test("Exactly one episode escalated; the other three transcribed here did not")
  func episodesAreCategorised() {
    let report = Self.report()
    #expect(report.escalatedEpisodeCount == 1)
    #expect(report.nonEscalatingEpisodes.map(\.startMs) == [57326, 1_050_807, 1_571_961])
    // Each was seconds long, not minutes — that is what made them blips.
    for episode in report.nonEscalatingEpisodes {
      let duration = try? #require(episode.durationMs)
      #expect((duration ?? .max) < 5000)
    }
  }

  /// Before this fix the same run left 52 entries here, almost all benign.
  /// "And nothing else" is only checkable if the list is short enough to
  /// read.
  @Test("unexplainedEvents holds only genuinely unexpected entries")
  func unexplainedIsShortAndMeaningful() {
    let report = Self.report()
    #expect(!report.unexplainedEvents.contains { $0.isLivenessHeartbeat })
    #expect(!report.unexplainedEvents.contains { $0.kind == .audioEvent(.enteredGoodZone) })
    #expect(report.unexplainedEvents.count <= 4, "got: \(report.unexplainedEvents)")
  }

  /// The recovery fired once. Two later `faceReacquired`s exist in the log,
  /// but each follows its own `faceLost`, so they are separate episodes —
  /// the distinction the old duplicate check missed.
  @Test("A later faceReacquired that follows a fresh faceLost is not a duplicate recovery")
  func laterBlipsAreNotDuplicateRecoveries() {
    let report = Self.report()
    let recovery = report.rungs.first { $0.rung == .recovery }
    #expect(recovery?.matched == true)
    #expect(recovery?.note.contains("exactly once") == true)
  }
}
