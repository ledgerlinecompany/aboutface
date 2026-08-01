import Testing

@testable import AboutFaceCore

/// §5.2 Monitor mode: "Hard rate limit: max 1 announcement per 20s. Same
/// condition not repeated within 3 minutes." §16 (maintainer decision,
/// 2026-08-01): these limits are `FeedbackConfig`-driven and
/// mode-selectable; this suite exercises `FeedbackConfig.defaults.monitor`
/// (20_000ms global, 180_000ms per-condition).
struct FeedbackRouterRateLimitTests {

  @Test("a second, different announcement within 20s of the first is suppressed")
  func globalLimitSuppressesWithin20s() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    // First announcement: `.noSignal`, confirmed + dwelled at t0+800ms
    // (Monitor's N-frame threshold is 3; `Config.dwellMs` is mode-agnostic
    // 800ms).
    await ingestRepeated(router, noSignalOutput(), at: t0, count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))
    #expect(await audio.calls == [.play(.noSignal)])

    // A DIFFERENT condition, confirmed+dwelled 1000ms after the first
    // announcement (well inside the 20s global window) — blocked.
    await ingestRepeated(
      router, makeOutput(signalState: .lowConfidence), at: t0.plus(ms: 1000), count: 3)
    await router.ingest(makeOutput(signalState: .lowConfidence), at: t0.plus(ms: 1800))

    #expect(await audio.calls == [.play(.noSignal)])
  }

  @Test("the same condition is suppressed at 2:59 but allowed at 3:01")
  func perConditionLimitAt3Minutes() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    let lowConfidence = makeOutput(signalState: .lowConfidence)

    // First `.noSignal` announcement, successfully fired at t0+800ms —
    // every later window in this test is measured from here.
    await ingestRepeated(router, noSignalOutput(), at: t0, count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))
    #expect(await audio.calls == [.play(.noSignal)])

    // Leave `.noSignal` (so the next re-entry is a fresh dwell episode) and
    // come back to it so the dwell-fire ATTEMPT lands exactly 2:59
    // (179_000ms) after the first announcement (t0+800ms): confirm at
    // t0+179_000ms, dwell fires 800ms later at t0+179_800ms.
    //
    // The "leave" and "return" batches sit only 1ms apart, both far under
    // `.dwellMs` (800ms) — neither's own dwell timer gets a chance to fire
    // before being superseded, so the ONLY thing that reaches
    // `fire(...)` in this whole sequence is the final `.noSignal` attempt
    // at t0+179_800ms. (A wider gap between "leave" and "return" would let
    // the intervening `lowConfidence` state's own dwell come due and fire
    // for real on whatever frame happens to arrive next — correct
    // `FeedbackRouter` behavior for a real, continuously-held condition,
    // but noise this test doesn't want.) The global 20s limit is well
    // satisfied by t0+179_800ms regardless; only the 3-minute per-condition
    // limit is what's actually under test here.
    await ingestRepeated(router, lowConfidence, at: t0.plus(ms: 178_999), count: 3)
    await ingestRepeated(router, noSignalOutput(), at: t0.plus(ms: 179_000), count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 179_800))

    #expect(await audio.calls == [.play(.noSignal)])  // still just the first — 2:59 < 3:00

    // Leave and return to `.noSignal` once more (same close-together
    // pattern), landing the next dwell-fire attempt exactly 3:01
    // (181_000ms) after the first announcement: confirm at t0+181_000ms,
    // dwell fires at t0+181_800ms.
    await ingestRepeated(router, lowConfidence, at: t0.plus(ms: 180_999), count: 3)
    await ingestRepeated(router, noSignalOutput(), at: t0.plus(ms: 181_000), count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 181_800))

    #expect(await audio.calls == [.play(.noSignal), .play(.noSignal)])
  }
}
