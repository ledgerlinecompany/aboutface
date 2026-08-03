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

  @Test("flag off: no trim target ever appears; the plain atomic-arrival sequence is unchanged")
  func flagOff_preservesLegacyStopUpdates() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    // `Config.defaults` — gaze trim is OFF by default.
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 1000))
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 2000))

    // Same exact atomic-arrival call sequence
    // `FeedbackRouterGoodZoneTests.entersGoodZoneOnce` derives frame-by-
    // frame, for this test's default (gaze-trim-OFF) config: with the
    // flag off, `gazeTrimTarget` always returns `nil` (its own
    // `config.audio.gazeTrim.enabled` guard, checked first), so once
    // arrival is announced `updateContinuousSonification` resolves to
    // `nil` on every hold frame too — no per-frame trim `.update` calls,
    // the "legacy" pure silence-and-heartbeat posture this test's name
    // refers to. That is a NARROWER claim than "no `.update` calls at
    // all," though: atomic arrival's beacon-through-confirmation and the
    // arrival cut itself (`.update(nil)`) fire regardless of the trim
    // flag — see `FeedbackConfig.goodZoneChimeDelayMs`'s doc comment.
    let beaconTarget = SonificationTarget(
      errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false)
    // swiftlint:disable trailing_comma
    let expected: [MockAudioRenderer.Call] = [
      .update(beaconTarget),
      .update(beaconTarget),
      .update(beaconTarget),
      .update(beaconTarget),
      .play(.enteredGoodZone),
      .update(nil),
    ]
    // swiftlint:enable trailing_comma
    #expect(await audio.calls == expected)
  }

  @Test("enabled + Setup + confirmed good zone: trim targets flow every frame")
  func enabledInSetup_confirmedGoodZone_trimTargetsFlow() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(
      audio: audio, speech: speech, config: Self.gazeTrimConfig, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // 5 identical frames confirms `.goodZone` (nFrameSetup == 5) AND fires
    // `enteredGoodZone` atomically, in that same 5th `ingest` call
    // (`goodZoneChimeDelayMs` default 0 — see
    // `FeedbackRouterGoodZoneTests.entersGoodZoneOnce`'s derivation).
    // Because `ingest` now runs discrete processing (which sets
    // `confirmedState` and fires the entry earcon) BEFORE the continuous
    // channel, THIS SAME 5th frame already has `gazeTrimTarget` see
    // `confirmedState == .goodZone` — trim flows starting immediately, no
    // extra frame needed to "catch up." The extra ingest below merely
    // proves it keeps flowing on a subsequent hold frame too (this test's
    // actual point, per its name).
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
    // Confirms `.goodZone` + fires atomically; trim flows starting the
    // very same 5th frame (see `enabledInSetup_confirmedGoodZone_
    // trimTargetsFlow` above), so `calls.last` is already a trim update
    // right after the batch — the extra ingest below just re-confirms it
    // holds on a subsequent frame too.
    await ingestRepeated(router, trimOutput, at: t0, count: 5)
    await router.ingest(trimOutput, at: t0.plus(ms: 10))
    let trimCall = await audio.calls.last
    guard case .update(let trimTarget?) = trimCall, trimTarget.gazeTrimActive else {
      Issue.record("expected trim to be active before exit, got \(String(describing: trimCall))")
      return
    }

    // Same N-frame-confirmed-exit requirement as
    // `FeedbackRouterGoodZoneTests.exitResumesPositionalUpdates`: atomic
    // arrival gates the continuous channel's post-arrival branch on
    // `confirmedState` (the N-frame-CONFIRMED discrete state), not the raw
    // per-frame `framing.inDeadZone` — so a single raw exit frame stays
    // routed through `gazeTrimTarget` (whose own `confirmedState ==
    // .goodZone` guard still passes) rather than reverting to the beacon.
    // The beacon only resumes once 5 consecutive out-of-dead-zone frames
    // reconfirm `confirmedState` away from `.goodZone`.
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, exitOutput, at: t0.plus(ms: 20), count: 5)

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
