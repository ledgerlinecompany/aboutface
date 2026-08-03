import Testing

@testable import AboutFaceCore

/// §6.1's silence-ambiguity structure for the "everything is fine" state:
/// a one-shot confirmation earcon, positional-update silence while holding,
/// a mandatory liveness heartbeat every `FeedbackConfig.heartbeatIntervalMs`
/// (default 7000ms — "The heartbeat is not optional"), and resumed
/// positional feedback the instant the subject drifts back out of the dead
/// zone. Gaze-off-in-good-zone coverage (the app field finding, 2026-08-02
/// — see `FeedbackCondition.gazeOff`'s doc comment) lives in
/// `FeedbackRouterGoodZoneGazeTests`.
///
/// **Atomic arrival (reviewer fix, 2026-08-02 — field finding: "the chime
/// is about half a second after the sound cuts out… disorienting"):**
/// `FeedbackConfig.goodZoneChimeDelayMs` defaults to 0 and
/// `updateContinuousSonification` now plays the beacon THROUGH the N-frame
/// confirmation window instead of going silent for it, so the entry earcon
/// and the beacon's cut land on the SAME `ingest` call that confirms
/// `.goodZone` — see `entersGoodZoneOnce` below for the exact frame-by-frame
/// derivation, which every other test in this file builds on.
struct FeedbackRouterGoodZoneTests {

  @Test("entering good zone: atomic arrival's exact call sequence, then holds silent")
  func entersGoodZoneOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Derivation (nFrameSetup == 5, goodZoneChimeDelayMs == 0, both
    // defaults):
    //
    // Frames 1-4 (`pendingStreak` 1..4, all at the same instant `t0` —
    // §7.2 counts CONSECUTIVE FRAMES, not elapsed time, so a fixed test
    // instant repeated is a faithful stand-in): `pendingStreak <
    // nFrameThreshold`, so `confirmedState` stays `nil`.
    // `updateContinuousSonification`'s `arrivalAnnounced` (`confirmedState
    // == .goodZone && dwellFiredForCurrentEpisode`) is therefore `false`,
    // so EACH of these 4 frames sends a beacon `.update` — `inDeadZone`
    // forced `false` regardless of the raw framing (`goodZoneOutput()`
    // reports a dead-center, in-dead-zone reading, but arrival hasn't been
    // announced yet, so the beacon still plays through it — the "beacon
    // plays through confirmation" half of atomic arrival).
    //
    // Frame 5: `pendingStreak` reaches 5, `confirmedState` becomes
    // `.goodZone` DURING this same `ingest` call. `ingest`'s
    // discrete-then-continuous ordering (its own doc comment) means the
    // SAME call also runs `tickAnnouncements` — `tickGoodZone` fires the
    // entry earcon immediately (`goodZoneChimeDelayMs` 0 ⇒ its dwell gate
    // is satisfied at elapsed 0ms): `.play(.enteredGoodZone)` +
    // `.speak(.centered)` (Setup mode) — and THEN, because the continuous
    // channel now runs LAST, `updateContinuousSonification` sees
    // `arrivalAnnounced == true` and sends the beacon's cut,
    // `.update(nil)`. Cut and chime land on the SAME ingest, in that
    // order — the atomic arrival this whole reconciliation is named for.
    let beaconTarget = SonificationTarget(
      errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false)
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)

    // swiftlint:disable trailing_comma
    let expectedAtomicSequence: [MockAudioRenderer.Call] = [
      .update(beaconTarget),
      .update(beaconTarget),
      .update(beaconTarget),
      .update(beaconTarget),
      .play(.enteredGoodZone),
      .update(nil),
    ]
    // swiftlint:enable trailing_comma
    #expect(await audio.calls == expectedAtomicSequence)
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // Holding good zone must never produce a second `enteredGoodZone`, and
    // the beacon stays cut (`nil` deduped — dwell already fired for this
    // episode, and no heartbeat boundary has been crossed yet; see
    // `heartbeatsEvery7Seconds` below for that timer).
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 2000))
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 6000))
    #expect(await audio.calls == expectedAtomicSequence)
  }

  @Test(
    "arrival with gaze off-camera still fires enteredGoodZone (app field finding regression)")
  func gazeOffOnArrivalDoesNotBlockEnteredGoodZone() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Placement alone is the good zone now: `inDeadZone: true` with
    // `gazeOnCamera: false` must classify as `.goodZone`, not
    // `.problem(.gazeOff)` — the regression from the field finding ("the
    // actual success earcon isn't firing, I'm just getting dead air and
    // the 'look at the camera' announcement").
    let output = makeOutput(signalState: .ok, inDeadZone: true, gazeOnCamera: false)

    // Event-focused: this test's intent is "did enteredGoodZone fire," not
    // the exact interleaving with the confirmation-window beacon updates
    // `entersGoodZoneOnce` above already pins down exactly once — so it
    // filters to `.play` events via `playedEvents()` rather than
    // duplicating that brittle exact-sequence assertion here too.
    await ingestRepeated(router, output, at: t0, count: 5)
    #expect(await audio.playedEvents() == [.enteredGoodZone])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
  }

  @Test(
    "head tilt on arrival does not block enteredGoodZone (roll's cousin of the gaze regression)")
  func headTiltOnArrivalDoesNotBlockEnteredGoodZone() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // §4 extension: roll joins the gaze advisory (maintainer, 2026-08-02:
    // "Agreed, it's part of gaze") — `headLevel` is deliberately NOT part
    // of `inDeadZone` (`AnalysisEngine+Framing.swift`'s doc comment: the
    // beacon has no rotational axis to guide a tilt correction with), so a
    // tilted arrival must classify as `.goodZone`, same as gaze-off does
    // above, and still fire the entry chime.
    let output = makeOutput(signalState: .ok, inDeadZone: true, headLevel: false)

    await ingestRepeated(router, output, at: t0, count: 5)
    #expect(await audio.playedEvents() == [.enteredGoodZone])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
  }

  @Test("holding good zone for 21s fires heartbeats at 7s, 14s, and 21s")
  func heartbeatsEvery7Seconds() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // The 5th frame of this batch both confirms `.goodZone` and fires the
    // entry earcon atomically (`goodZoneChimeDelayMs` default 0 — see
    // `entersGoodZoneOnce` above for the frame-by-frame derivation), so
    // the heartbeat schedule (`nextHeartbeatAt = time.advanced(by:
    // heartbeatIntervalMs)`, set inside that same `tickGoodZone` call) is
    // seeded from `t0` itself, not from some later separate "entered"
    // call.
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    let entryFireTime = t0

    // Event-focused throughout (see `playedEvents()`'s doc comment) — this
    // test is about heartbeat CADENCE, not the interleaved beacon updates.
    // Just before each 7s boundary: no heartbeat yet.
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 6999))
    #expect(await audio.playedEvents() == [.enteredGoodZone])

    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 7000))
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 14000))
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 21000))

    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Format wins (see
    // FeedbackRouter+Announcements.swift for the same disagreement).
    // swiftlint:disable trailing_comma
    let expected: [AudioEvent] = [
      .enteredGoodZone,
      .livenessHeartbeat,
      .livenessHeartbeat,
      .livenessHeartbeat,
    ]
    // swiftlint:enable trailing_comma
    #expect(await audio.playedEvents() == expected)
  }

  @Test("exiting past N-frame-confirmed hysteresis resumes positional updates and re-arms entry")
  func exitResumesPositionalUpdates() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Confirms + fires atomically, per `entersGoodZoneOnce`'s derivation.
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)

    // Atomic arrival's `confirmedState`-gated continuous channel
    // (`updateContinuousSonification`'s `arrivalAnnounced`, which reads
    // `confirmedState == .goodZone` — the N-frame-CONFIRMED state — not
    // the raw per-frame `framing.inDeadZone`) means a SINGLE raw exit
    // frame no longer resumes the beacon: the same overshoot-flicker fix
    // that keeps the beacon playing through a brief IN-zone blip during
    // entry confirmation also keeps it cut through a brief OUT-of-zone
    // blip once arrived (that frame instead resolves through
    // `gazeTrimTarget`, which returns `nil` with the trim flag off,
    // default here — same silent result, just no longer routed through
    // the beacon branch). Only once the exit itself reaches §7.2's
    // N-frame threshold — `confirmedState` actually leaving `.goodZone` —
    // does the beacon resume, on that Nth frame, in the SAME `ingest` call
    // that reconfirms the discrete state (mirroring entry's own
    // atomicity).
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, exitOutput, at: t0.plus(ms: 900), count: 5)

    let expectedTarget = SonificationTarget(
      errorX: 0.5, errorY: 0, distanceError: 0, inDeadZone: false)
    #expect(await audio.calls.last == .update(expectedTarget))

    // Re-entering good zone afterward must announce `enteredGoodZone`
    // again — confirms the one-shot latch was re-armed on exit, not stuck
    // permanently "already announced." Fires atomically on the 5th frame
    // of this batch too, same as the very first entry.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1000), count: 5)

    let enteredGoodZoneCount = await audio.playedEvents().filter { $0 == .enteredGoodZone }.count
    #expect(enteredGoodZoneCount == 2)
  }
}
