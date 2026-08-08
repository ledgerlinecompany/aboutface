import Testing

@testable import AboutFaceCore

/// Phase 4.5's status pulse and the silencing of the beacon during monitoring
/// (`docs/design/phase-4.5-app-design.md` §3.3, §3.3.1).
///
/// Two behaviors, one change of posture: while the app is watching rather than
/// guiding, it emits a steady pulse and no positional tone. Before this, it did
/// the opposite of both — the heartbeat stopped the moment the user drifted out
/// of the good zone, and the beacon started.
struct FeedbackRouterPulseTests {

  // MARK: - The inversion this fixes

  /// The headline correction. Drifting out of frame used to clear
  /// `nextHeartbeatAt`, so the app went silent exactly when something was
  /// wrong and the user could not tell "I have drifted" from "it died" —
  /// §6.1's own silence-ambiguity failure, inverted.
  @Test("The pulse keeps running while out of the good zone in monitoring")
  func pulseContinuesOutsideGoodZone() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    // Settle in the good zone, then drift out and STAY out.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1), count: 3)
    await ingestRepeated(router, framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 100), count: 3)

    // Well past the 7s heartbeat cadence, still out of the zone.
    await router.ingest(framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 7200))
    #expect(await audio.playedEvents().contains(.livenessHeartbeat))
  }

  @Test("The pulse keeps its cadence across many frames rather than firing per frame")
  func pulseHoldsCadence() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1), count: 3)
    // 30 seconds of frames at 5Hz — 150 ingests, but the cadence is 7s.
    for index in 0..<150 {
      await router.ingest(goodZoneOutput(), at: t0.plus(ms: 200 + index * 200))
    }
    let pulses = await audio.playedEvents().filter { $0 == .livenessHeartbeat }.count
    // ~30s at 7s cadence is 4; allow the boundary either way.
    #expect(pulses >= 3 && pulses <= 5, "got \(pulses) pulses in ~30s")
  }

  // MARK: - What the pulse yields to

  /// §7.3's ladder owns the soundscape when there is no face, and its 30s STOP
  /// requires total silence. A pulse continuing underneath would defeat it.
  @Test("The pulse stops while the face is lost, leaving the ladder in charge")
  func pulseYieldsToFaceLost() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1), count: 3)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 100), count: 3)
    let eventsAtLoss = await audio.playedEvents().count

    // Across two full cadences of absence, no pulse.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 7500))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 14500))
    let pulsesDuringLoss = await audio.playedEvents().dropFirst(eventsAtLoss)
      .filter { $0 == .livenessHeartbeat }.count
    #expect(pulsesDuringLoss == 0)
  }

  /// Cadence restarts on reacquisition rather than firing a pulse that came
  /// due during an absence nobody was present for.
  @Test("The cadence restarts after the face returns")
  func cadenceRestartsAfterReacquisition() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 20_000))
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 20_100), count: 3)
    let atReturn = await audio.playedEvents().count

    // A pulse must NOT land immediately on return...
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 20_300))
    let immediate = await audio.playedEvents().dropFirst(atReturn)
      .filter { $0 == .livenessHeartbeat }.count
    #expect(immediate == 0)

    // ...but must land one cadence later.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 27_500))
    let later = await audio.playedEvents().dropFirst(atReturn)
      .filter { $0 == .livenessHeartbeat }.count
    #expect(later == 1)
  }

  // MARK: - The beacon is a converging instrument only

  /// Until Phase 4.5 `updateContinuousSonification` had no mode gate at all,
  /// so drifting out of the dead zone during a call played the positional
  /// tone — continuous unprompted sound, contrary to the near-silence
  /// decision (design doc §3.3).
  @Test("No positional beacon is ever sent while monitoring")
  func noBeaconWhileMonitoring() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 1), count: 5)
    await router.ingest(framingErrorOutput(errorX: -0.4), at: t0.plus(ms: 500))

    let targets = await audio.calls.compactMap { call -> SonificationTarget?? in
      if case .update(let target) = call { return target }
      return nil
    }
    #expect(!targets.contains { $0 != nil }, "a beacon target was sent while monitoring")
  }

  /// The same drift in converging still guides, unchanged — the beacon was not
  /// removed, it was scoped.
  @Test("The beacon still plays while converging")
  func beaconStillPlaysWhileConverging() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.ingest(framingErrorOutput(errorX: 0.5), at: t0)
    guard case .update(let target?) = await audio.calls.last else {
      Issue.record("expected a beacon target while converging, got \(await audio.calls)")
      return
    }
    #expect(target.errorX == 0.5)
  }

  /// Converging keeps its good-zone-scoped heartbeat: there the beacon is the
  /// continuous signal, and the heartbeat means "you are placed and I am still
  /// here." Only monitoring's ambient behavior changed.
  @Test("Converging does not fire the pulse outside the good zone")
  func convergingKeepsGoodZoneScopedHeartbeat() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 1), count: 5)
    await router.ingest(framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 7500))
    #expect(!(await audio.playedEvents().contains(.livenessHeartbeat)))
  }
}
