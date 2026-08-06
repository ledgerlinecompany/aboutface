import AboutFaceCore
import Testing

/// `AcceptanceEvaluator` against hand-built event sequences — no live
/// camera, no `AVCaptureDevice.DiscoverySession` anywhere in this file
/// (§13 Phase 4 PR brief: a test that merely reads back "no such device"
/// still enumerates hardware and has hung CI for 45 minutes twice). Every
/// fixture below is a plain `[AcceptanceEvent]` literal; `AcceptanceEvaluator
/// .evaluate(_:)` is pure and synchronous, so these are ordinary
/// synchronous `@Test`s, no `async` needed.
///
/// Uses `FeedbackConfig.defaults`/`.monitor` throughout (§7.3's real shipped
/// numbers: 1500ms earcon delay, 5000ms speech delay, 30000ms stop delay),
/// so the millisecond literals below read directly off `FeedbackConfig
/// .swift`'s own doc comments rather than being arbitrary.
struct AcceptanceEvaluatorTests {
  /// Default tolerances for tests that don't care about the exact slack —
  /// deliberately generous (250ms) so ordinary rounding in a hand-built
  /// fixture never fails a test for the wrong reason. Tests that assert on
  /// tolerance BEHAVIOR (the off-schedule case below) pick a narrower value
  /// explicitly instead of relying on this one.
  private static let tolerances = AcceptanceTolerances(
    rungTimingToleranceMs: 250, awayPollIntervalMs: 1000)

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  private static func evaluate(_ events: [AcceptanceEvent], episodeStartMs: Int? = 0)
    -> AcceptanceReport
  {
    // swiftlint:enable opening_brace
    AcceptanceEvaluator.evaluate(
      AcceptanceEvaluator.Input(
        events: events, feedbackConfig: .defaults, mode: .monitor, tolerances: tolerances,
        episodeStartMs: episodeStartMs))
  }

  // swiftlint:disable opening_brace
  private static func rung(_ report: AcceptanceReport, _ rung: AcceptanceReport.Rung)
    -> AcceptanceReport.RungResult
  {
    // swiftlint:enable opening_brace
    report.rungs.first { $0.rung == rung }!
  }

  // MARK: - The ideal sequence

  @Test("Ideal escalate-then-stop-then-recover sequence: all four rungs matched")
  func idealSequenceMatches() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 600_000, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 600_050, kind: .userLikelyAway(false)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    #expect(report.rungs.count == 4)
    for result in report.rungs {
      #expect(result.matched, "\(result.rung): \(result.note)")
    }
    // The benign userLikelyAway(false) clearing transition is real,
    // correct behavior but is NOT one of the four canonical markers this
    // evaluator matches against -- see AcceptanceEvaluator's own doc
    // comment on why nothing is silently reclassified as "expected."
    #expect(report.unexplainedEvents.count == 1)
    #expect(report.strayRendererActivityDuringStop.isEmpty)
    #expect(report.referenceEpisodeStartMs == 0)
    #expect(!report.referenceEpisodeStartIsInferred)
  }

  @Test("A completely empty session reports all four rungs missing, nothing unexplained")
  func emptySessionReportsAllMissing() {
    let report = Self.evaluate([])
    for result in report.rungs {
      #expect(!result.matched)
      #expect(result.observedElapsedMs == nil)
      #expect(result.note.contains("missing"))
    }
    #expect(report.unexplainedEvents.isEmpty)
    #expect(report.strayRendererActivityDuringStop.isEmpty)
  }

  // MARK: - A missing rung is reported as missing, not silently skipped

  @Test("A missing rung (rung 2 never fires) is reported as missing; the others are unaffected")
  func missingRungReportedAsMissing() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      // Rung 2 never fires -- e.g. faceLostSpeechEnabled == false in the
      // config the session actually ran under.
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 60000, kind: .audioEvent(.faceReacquired)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    let spokenNoFace = Self.rung(report, .spokenNoFace)
    #expect(!spokenNoFace.matched)
    #expect(spokenNoFace.observedElapsedMs == nil)
    #expect(spokenNoFace.note.contains("missing"))

    #expect(Self.rung(report, .earcon).matched)
    #expect(Self.rung(report, .stop).matched)
    #expect(Self.rung(report, .recovery).matched)
  }

  // MARK: - A stray extra event is reported, never silently absorbed

  /// §6.1's heartbeat fires every 7s while placed, so a 30-minute run puts
  /// ~170 of them in the record. Those must not bury `unexplainedEvents` —
  /// the one list a human has to read to check "and nothing else" — but the
  /// split is by POSITION, not by kind: a heartbeat inside the face-lost
  /// episode still counts as evidence (see
  /// `strayEventReportedAsUnexplained`).
  @Test("Heartbeats outside the episode are bucketed; the ideal sequence's rungs still match")
  func routineHeartbeatsAreBucketedSeparately() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 500, kind: .audioEvent(.livenessHeartbeat)),
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 600_000, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 607_000, kind: .audioEvent(.livenessHeartbeat)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    #expect(report.heartbeats.map(\.elapsedMs) == [500, 607_000])
    #expect(!report.unexplainedEvents.contains { $0.isLivenessHeartbeat })
    for result in report.rungs {
      #expect(result.matched, "\(result.rung): \(result.note)")
    }
  }

  @Test("A stray extra event surfaces in unexplainedEvents, not folded into a rung")
  func strayEventReportedAsUnexplained() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      // Stray: nothing in §7.3's ladder fires a heartbeat mid-episode.
      AcceptanceEvent(elapsedMs: 2000, kind: .audioEvent(.livenessHeartbeat)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 600_000, kind: .audioEvent(.faceReacquired)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    #expect(report.unexplainedEvents.contains { $0.elapsedMs == 2000 })
    // The stray event does not stop the real rungs from matching.
    for result in report.rungs {
      #expect(result.matched, "\(result.rung): \(result.note)")
    }
  }

  @Test("Renderer activity strictly between the STOP and recovery is flagged as unsafe silence")
  func strayRendererActivityDuringStopIsFlagged() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      // §7.3: "nothing left to do on any later frame" once rung 3 fires.
      // Any renderer call here is the single most safety-critical bug this
      // instrument exists to catch.
      AcceptanceEvent(elapsedMs: 35000, kind: .audioEvent(.enteredGoodZone)),
      AcceptanceEvent(elapsedMs: 600_000, kind: .audioEvent(.faceReacquired)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    #expect(report.strayRendererActivityDuringStop.count == 1)
    #expect(report.strayRendererActivityDuringStop.first?.elapsedMs == 35000)
    #expect(report.unexplainedEvents.contains { $0.elapsedMs == 35000 })
  }

  // MARK: - Duplicate recovery

  @Test("faceReacquired firing twice is reported as a mismatch, not a silent double-match")
  func duplicateRecoveryIsReported() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 30000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 600_000, kind: .audioEvent(.faceReacquired)),
      AcceptanceEvent(elapsedMs: 600_100, kind: .audioEvent(.faceReacquired)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    let recovery = Self.rung(report, .recovery)
    #expect(!recovery.matched)
    #expect(recovery.observedElapsedMs == 600_000)
    #expect(recovery.note.contains("AGAIN"))
    #expect(report.unexplainedEvents.contains { $0.elapsedMs == 600_100 })
  }

  // MARK: - Out-of-order events are not silently accepted

  @Test("An early, out-of-order occurrence of a rung's event kind does not satisfy that rung")
  func outOfOrderOccurrenceIsNotAccepted() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 1500, kind: .audioEvent(.faceLost)),
      // Spurious: userLikelyAway briefly (and wrongly) reads true BEFORE
      // rung 2 has even spoken -- e.g. a polling glitch. This must not be
      // accepted as rung 3.
      AcceptanceEvent(elapsedMs: 3000, kind: .userLikelyAway(true)),
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
      AcceptanceEvent(elapsedMs: 60000, kind: .audioEvent(.faceReacquired)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events)

    let stop = Self.rung(report, .stop)
    #expect(!stop.matched)
    #expect(stop.observedElapsedMs == nil)
    #expect(stop.note.contains("missing"))
    #expect(report.unexplainedEvents.contains { $0.elapsedMs == 3000 })

    // Rungs 1, 2, and recovery are still judged correctly -- the
    // out-of-order occurrence contaminates only the rung it falsely
    // resembled, not the whole report.
    #expect(Self.rung(report, .earcon).matched)
    #expect(Self.rung(report, .spokenNoFace).matched)
    #expect(Self.rung(report, .recovery).matched)
  }

  // MARK: - Off-schedule timing is reported, not silently accepted as a match

  @Test("A rung that fires, but badly off schedule, is reported unmatched with the deviation")
  func offScheduleRungIsNotMatched() {
    let narrowTolerances = AcceptanceTolerances(
      rungTimingToleranceMs: 100, awayPollIntervalMs: 1000)
    let events: [AcceptanceEvent] = [
      // Expected ~1500ms; fires at 10000ms instead.
      AcceptanceEvent(elapsedMs: 10000, kind: .audioEvent(.faceLost))
    ]
    let report = AcceptanceEvaluator.evaluate(
      AcceptanceEvaluator.Input(
        events: events, feedbackConfig: .defaults, mode: .monitor, tolerances: narrowTolerances,
        episodeStartMs: 0))

    let earcon = Self.rung(report, .earcon)
    #expect(!earcon.matched)
    #expect(earcon.observedElapsedMs == 10000)
    #expect(earcon.note.contains("OFF SCHEDULE"))
  }

  // MARK: - Reference episode start: explicit vs. inferred

  @Test(
    "With no explicit episode start, the reference is reconstructed from rung 1 and flagged inferred"
  )
  func referenceStartInferredFromRung1() {
    // Onset presumed at 10000ms; rung 1 fires 1500ms later, per Monitor's
    // configured delay.
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 11500, kind: .audioEvent(.faceLost)),
      AcceptanceEvent(elapsedMs: 15000, kind: .spokenPhrase(Lexicon.Instruction.noFace)),
    ]  // swiftlint:disable:previous trailing_comma
    let report = Self.evaluate(events, episodeStartMs: nil)

    #expect(report.referenceEpisodeStartMs == 10000)
    #expect(report.referenceEpisodeStartIsInferred)
    #expect(Self.rung(report, .spokenNoFace).matched)
  }

  @Test("With no rung 1 and no explicit episode start, absolute timing is left unverifiable")
  func noReferenceAvailableLeavesTimingUnverified() {
    let events: [AcceptanceEvent] = [
      AcceptanceEvent(elapsedMs: 5000, kind: .spokenPhrase(Lexicon.Instruction.noFace))
    ]
    let report = Self.evaluate(events, episodeStartMs: nil)

    #expect(report.referenceEpisodeStartMs == nil)
    #expect(!report.referenceEpisodeStartIsInferred)
    let spokenNoFace = Self.rung(report, .spokenNoFace)
    #expect(spokenNoFace.matched)
    #expect(spokenNoFace.expectedElapsedMs == nil)
    #expect(spokenNoFace.note.contains("order only"))
  }

  // MARK: - Tolerances are Config-derived, not a hardcoded magic number

  @Test("AcceptanceTolerances.derived reads Config's own N-frame count and analysis rate")
  func derivedTolerancesReadConfig() {
    // Config.defaults: FeedbackConfig.nFrameMonitor == 3, Camera.monitor
    // .analysisHz == 5.0 -- (3 / 5.0) * 1000 == 600ms.
    let tolerances = AcceptanceTolerances.derived(from: .defaults, awayPollIntervalMs: 1000)
    #expect(tolerances.rungTimingToleranceMs == 600)
    #expect(tolerances.awayPollIntervalMs == 1000)
  }
}
