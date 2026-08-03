import Testing

@testable import AboutFaceCore

/// §7.3's face-lost escalation ladder, all four rungs: "0 – [delay]:
/// Nothing... [delay]: Distinct earcon. Non-positional... ~5s: Spoken...
/// ~30s: STOP." Plus recovery: "On face reacquisition... announce recovery
/// once." The rung-1 delay is MODE-SELECTED (app field finding, 2026-08-02:
/// "it takes ~1.5s for the no-face warning to sound after the tone stops")
/// — Setup's active convergence loop uses 500ms (`FeedbackConfig
/// .faceLostEarconDelaySetupMs`), Monitor keeps the original 1500ms
/// (`faceLostEarconDelayMonitorMs`) per §7.3's own "covers turning to a
/// second monitor, reaching for coffee" rationale. See
/// `FeedbackRouter.faceLostEarconDelayMs`'s doc comment for the full story.
/// Rungs 2/3 and recovery live in `FeedbackRouter+FaceLost.swift`; the
/// rung-0/1 tests below predate that file (Phase 3) and stay mode-split the
/// same way for continuity with it.
struct FeedbackRouterFaceLostTests {

  @Test("Setup: nothing happens before 500ms of face loss")
  func setupNothingBefore500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 499))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("Setup: 500ms of face loss fires a single non-positional earcon")
  func setupEarconAt500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 499))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 500))

    #expect(await audio.calls == [.play(.faceLost)])
    // Rung 2 (~5s, spoken "No face.") hasn't come due yet.
    #expect(await speech.calls.isEmpty)

    // Continuing to hold face-lost must not refire the earcon. Stays
    // strictly before rung 2's 5000ms boundary
    // (`FeedbackRouterFaceLostEscalationTests` covers that transition) so
    // this test pins down rung 1's own "fires at most once" latch in
    // isolation.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 4999))
    #expect(await audio.calls == [.play(.faceLost)])
    #expect(await speech.calls.isEmpty)
  }

  @Test("Monitor: nothing happens before 1500ms of face loss")
  func monitorNothingBefore1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Monitor's N-frame threshold is 3 (`nFrameMonitor`).
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("Monitor: 1500ms of face loss fires a single non-positional earcon")
  func monitorEarconAt1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))

    #expect(await audio.calls == [.play(.faceLost)])

    // Continuing to hold face-lost must not refire the earcon. Bypasses
    // Monitor's rate limit deliberately (§7.3's ladder is exempt — see
    // `tickFaceLostLadder`'s doc comment), so this is purely the "fires at
    // most once per episode" latch under test, not the rate limiter. Stays
    // strictly before rung 2's 5000ms boundary
    // (`FeedbackRouterFaceLostEscalationTests` covers that transition).
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 4999))
    #expect(await audio.calls == [.play(.faceLost)])
    #expect(await speech.calls.isEmpty)
  }

  @Test("reacquiring the face after the earcon fires faceReacquired once")
  func reacquisitionFiresFaceReacquiredOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 500))
    #expect(await audio.playedEvents() == [.faceLost])

    // Reacquire: 5 consecutive good-zone frames confirm the recovery.
    // Atomic arrival means the SAME 5th frame that reconfirms
    // `confirmedState` away from `.problem(.faceLost)` both fires
    // `.faceReacquired` (in `onConfirmedStateChanged`, called first) AND,
    // because the newly confirmed state is `.goodZone` with
    // `goodZoneChimeDelayMs` 0, fires `.enteredGoodZone` too — in the SAME
    // `ingest` call's `tickAnnouncements`, no longer a separate, later
    // 800ms-dwell call the way it was pre-atomic-arrival. Event-focused:
    // filters out the interleaved confirmation-window beacon `.update`
    // calls (frames 1-4 of this batch haven't reconfirmed yet, so they're
    // still raw `.ok` beacon frames — see `MockAudioRenderer
    // .playedEvents()`'s doc comment) — this test's intent is the
    // RECOVERY event ordering, not the continuous channel.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 600), count: 5)

    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired, .enteredGoodZone])

    // Holding the recovered state must not refire anything.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 700))
    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired, .enteredGoodZone])
  }

  @Test("a face-lost episode that never reaches the earcon does not announce a recovery")
  func briefLossBeforeEarconIsSilentBothWays() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Confirmed face-lost, but reacquired well before Setup's 500ms earcon
    // rung — `faceLostRung` never reaches 1, so `onConfirmedStateChanged`'s
    // `hadEscalated` gate on `.faceReacquired` stays closed. The 5-frame
    // reacquisition batch below DOES reach `.goodZone` though, and atomic
    // arrival fires THAT episode's own `enteredGoodZone` on the confirming
    // frame (`goodZoneChimeDelayMs` 0) — a real, correct chime for a real
    // placement, not the recovery event under test here. Event-focused:
    // asserts `.faceReacquired` specifically never appears, rather than
    // total silence (no longer true, or even desirable, post-atomic-arrival
    // — contrast `reacquisitionFiresFaceReacquiredOnce` above, the
    // escalated case where reacquisition DOES announce).
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 200), count: 5)

    #expect(await audio.playedEvents() == [.enteredGoodZone])
  }
}
