import Testing

@testable import AboutFaceCore

/// Tuning round 5 (maintainer-designed audition prototype — `Config
/// .AudioGazeTrim`, default OFF): "instead of pure silence + heartbeat, a
/// gaze trim phase MAY take over the continuous channel" once confirmed in
/// the good zone. See `FeedbackRouter+GazeTrim.swift`'s doc comment for the
/// full activation-gating list this exercises.
struct FeedbackRouterGazeTrimTests {

  /// A `Config` with gaze trim enabled and a captured neutral baseline —
  /// every test below builds on this so hand-derived deviations
  /// (`geometry.yaw/pitch - neutral*Degrees`) are simple round numbers.
  private static var gazeTrimConfig: Config {
    var config = Config.defaults
    config.audio.gazeTrim.enabled = true
    config.targetFraming.neutralYawDegrees = 5
    config.targetFraming.neutralPitchDegrees = -5
    return config
  }

  @Test("flag off: legacy stop-updates behavior is unchanged (default config)")
  func flagOff_preservesLegacyStopUpdates() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    // `Config.defaults` — gaze trim is OFF by default.
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 800))  // enters good zone
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 1000))
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 2000))

    // Exactly the pre-existing assertion from `FeedbackRouterGoodZoneTests
    // .entersGoodZoneOnce`: only the one-shot earcon, never an
    // `audio.update` call.
    #expect(await audio.calls == [.play(.enteredGoodZone)])
  }

  @Test("enabled + Setup + confirmed good zone: trim targets flow every frame")
  func enabledInSetup_confirmedGoodZone_trimTargetsFlow() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(
      audio: audio, speech: speech, config: Self.gazeTrimConfig, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // 5 identical frames confirms `.goodZone` (nFrameSetup == 5); a 6th
    // frame is the first one `gazeTrimTarget` can see `confirmedState ==
    // .goodZone` (set during the 5th ingest, read at the START of the
    // 6th — see `updateContinuousSonification`'s call ordering in
    // `ingest(_:at:)`).
    let output = goodZoneOutput(yaw: 15, pitch: -5)  // yawDeviation = 10, pitchDeviation = 0
    await ingestRepeated(router, output, at: t0, count: 5)
    await router.ingest(output, at: t0.plus(ms: 10))

    let calls = await audio.calls
    guard case .update(let target?) = calls.last else {
      Issue.record("expected a trim SonificationTarget update, got \(calls)")
      return
    }
    #expect(target.gazeTrimActive)
    #expect(target.inDeadZone)
    #expect(target.yawDeviationDegrees == 10)
    #expect(target.pitchDeviationDegrees == 0)
  }

  @Test("exiting the good zone reverts to the beacon exactly as now")
  func exitingGoodZone_revertsToBeacon() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(
      audio: audio, speech: speech, config: Self.gazeTrimConfig, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    let trimOutput = goodZoneOutput(yaw: 15, pitch: -5)
    await ingestRepeated(router, trimOutput, at: t0, count: 5)
    await router.ingest(trimOutput, at: t0.plus(ms: 10))
    let trimCall = await audio.calls.last
    guard case .update(let trimTarget?) = trimCall, trimTarget.gazeTrimActive else {
      Issue.record("expected trim to be active before exit, got \(String(describing: trimCall))")
      return
    }

    // Same shape as `FeedbackRouterGoodZoneTests.exitResumesPositionalUpdates`:
    // the very next out-of-dead-zone frame resumes the beacon immediately,
    // not gated by N-frame confirmation.
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await router.ingest(exitOutput, at: t0.plus(ms: 20))

    let expectedBeaconTarget = SonificationTarget(
      errorX: 0.5, errorY: 0, distanceError: 0, inDeadZone: false)
    #expect(await audio.calls.last == .update(expectedBeaconTarget))
  }

  @Test("Monitor mode never activates trim even when enabled")
  func monitorMode_neverActivatesTrim() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(
      audio: audio, speech: speech, config: Self.gazeTrimConfig, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    let output = goodZoneOutput(yaw: 15, pitch: -5)
    await ingestRepeated(router, output, at: t0, count: 5)
    await router.ingest(output, at: t0.plus(ms: 10))
    await router.ingest(output, at: t0.plus(ms: 20))

    // Monitor's own rate limiting/earcon posture is untouched; the point
    // here is narrower: no `.update` call ever carries `gazeTrimActive ==
    // true`.
    let trimCalls = await audio.calls.filter {
      if case .update(let target?) = $0 { return target.gazeTrimActive }
      return false
    }
    #expect(trimCalls.isEmpty)
  }

  @Test("deviations within the dead band collapse to exactly neutral (steadiness)")
  func deviationsWithinDeadBand_collapseToNeutral() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(
      audio: audio, speech: speech, config: Self.gazeTrimConfig, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // `deadBandDegrees` default is 3°; neutral yaw/pitch are 5°/-5°, so
    // yaw = 6°, pitch = -6° are 1° deviations — jitter well inside the
    // dead band.
    let jitterA = goodZoneOutput(yaw: 6, pitch: -6)
    let jitterB = goodZoneOutput(yaw: 4, pitch: -4)
    await ingestRepeated(router, jitterA, at: t0, count: 5)
    await router.ingest(jitterA, at: t0.plus(ms: 10))
    await router.ingest(jitterB, at: t0.plus(ms: 20))
    await router.ingest(jitterA, at: t0.plus(ms: 30))

    let calls = await audio.calls
    let trimTargets: [SonificationTarget] = calls.compactMap {
      if case .update(let target?) = $0, target.gazeTrimActive { return target }
      return nil
    }
    #expect(trimTargets.count >= 2)
    for target in trimTargets {
      #expect(target.yawDeviationDegrees == 0)
      #expect(target.pitchDeviationDegrees == 0)
    }
  }
}

/// `goodZoneOutput` with an overridable head pose, for gaze-trim tests only
/// — the shared `goodZoneOutput()` in `FeedbackRouterTestSupport.swift`
/// stays yaw/pitch-less (0, 0) since no pre-existing test needs a pose.
private func goodZoneOutput(yaw: Float, pitch: Float) -> EngineOutput {
  makeOutput(signalState: .ok, inDeadZone: true, gazeOnCamera: true, yaw: yaw, pitch: pitch)
}
