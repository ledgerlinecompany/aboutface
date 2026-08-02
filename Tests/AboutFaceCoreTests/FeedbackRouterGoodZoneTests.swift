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
struct FeedbackRouterGoodZoneTests {

  @Test("entering good zone fires enteredGoodZone once and stops positional updates")
  func entersGoodZoneOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    #expect(await audio.calls.isEmpty)

    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 800))
    #expect(await audio.calls == [.play(.enteredGoodZone)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // Holding good zone must never produce a second `enteredGoodZone`, and
    // must never call `audio.update` — no `SonificationTarget` updates
    // while inside the dead zone.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 2000))
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 6000))
    let callsBeforeHeartbeat = await audio.calls
    #expect(callsBeforeHeartbeat == [.play(.enteredGoodZone)])
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

    await ingestRepeated(router, output, at: t0, count: 5)
    #expect(await audio.calls.isEmpty)

    await router.ingest(output, at: t0.plus(ms: 800))
    #expect(await audio.calls == [.play(.enteredGoodZone)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
  }

  @Test("holding good zone for 21s fires heartbeats at 7s, 14s, and 21s")
  func heartbeatsEvery7Seconds() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    let entryFireTime = t0.plus(ms: 800)
    await router.ingest(goodZoneOutput(), at: entryFireTime)  // enters good zone

    // Just before each 7s boundary: no heartbeat yet.
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 6999))
    #expect(await audio.calls == [.play(.enteredGoodZone)])

    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 7000))
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 14000))
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 21000))

    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Format wins (see
    // FeedbackRouter+Announcements.swift for the same disagreement).
    // swiftlint:disable trailing_comma
    let expected: [MockAudioRenderer.Call] = [
      .play(.enteredGoodZone),
      .play(.livenessHeartbeat),
      .play(.livenessHeartbeat),
      .play(.livenessHeartbeat),
    ]
    // swiftlint:enable trailing_comma
    #expect(await audio.calls == expected)
  }

  @Test("exiting past hysteresis resumes positional updates and re-arms entry")
  func exitResumesPositionalUpdates() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 800))  // entered

    // `AnalysisEngine`'s hysteresis is what decides WHEN `inDeadZone` flips
    // back to `false` — from `FeedbackRouter`'s point of view that's just
    // the next frame reporting `inDeadZone == false`, and positional
    // updates must resume IMMEDIATELY on the very first such frame, not
    // gated by §7.2's N-frame filter (that filter only gates the DISCRETE
    // announcement pipeline — see `updateContinuousSonification`'s doc
    // comment for why the continuous channel is deliberately exempt).
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await router.ingest(exitOutput, at: t0.plus(ms: 900))

    let expectedTarget = SonificationTarget(
      errorX: 0.5, errorY: 0, distanceError: 0, inDeadZone: false)
    #expect(await audio.calls.last == .update(expectedTarget))

    // N-frame-confirm the exit as a discrete condition change too (5
    // consecutive out-of-dead-zone frames), so the good-zone "already
    // announced" latch actually re-arms.
    await ingestRepeated(router, exitOutput, at: t0.plus(ms: 900), count: 5)

    // Re-entering good zone afterward must announce `enteredGoodZone`
    // again — confirms the one-shot latch was re-armed on exit, not stuck
    // permanently "already announced."
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1000), count: 5)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 1800))

    let enteredGoodZoneCount = await audio.calls.filter { $0 == .play(.enteredGoodZone) }.count
    #expect(enteredGoodZoneCount == 2)
  }
}
