import Testing

@testable import AboutFaceCore

/// Regression tests for the continuous channel's resolve-and-send shape
/// (app field finding: "if face stops being detected it makes the sound for
/// that but the tone doesn't stop"). The channel must send exactly one of
/// {beacon target, trim target, nil} per frame, deduping nil.
///
/// **Atomic arrival (reviewer fix, 2026-08-02 — field finding: "the chime
/// is about half a second after the sound cuts out… disorienting"):** the
/// beacon now plays THROUGH the §7.2 N-frame confirmation window instead of
/// going silent for it, and the entry earcon + the beacon's cut land on the
/// SAME `ingest` call that confirms `.goodZone` (`goodZoneChimeDelayMs`
/// default 0) — see `arrivalCutAndChimeLandOnSameIngest` and
/// `subThresholdZoneTransitNeitherCutsNorChimes` below, which replace the
/// old (now-false) "dead-zone entry cuts the beacon immediately" claim.
struct FeedbackRouterContinuousChannelTests {

  @Test("Face lost after active beacon sends update(nil) — the tone stops")
  func faceLostSilencesBeacon() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.ingest(framingErrorOutput(errorX: 0.2), at: t0)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 33))

    let updates = await updateArguments(audio)
    #expect(updates.first != nil && updates.first! != nil, "first frame sends an active target")
    #expect(
      updates.last != nil && updates.last! == nil, "face loss must send update(nil), got \(updates)"
    )
  }

  @Test("nil sends are deduped: a faceless stream never spams update(nil)")
  func nilDeduped() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    var t = clock.now

    for _ in 0..<4 {
      await router.ingest(faceLostOutput(), at: t)
      t = t.plus(ms: 33)
    }
    let updates = await updateArguments(audio)
    #expect(updates.isEmpty, "never-active stream should send no updates, got \(updates)")
  }

  @Test("arrival cut and chime land on the same ingest, in order: chime then cut")
  func arrivalCutAndChimeLandOnSameIngest() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Superseded the old "dead-zone entry cuts the beacon immediately, on
    // the very next frame" claim — the field finding that motivated THIS
    // reconciliation was the opposite complaint ("the chime is about half
    // a second after the sound cuts out… disorienting"). Derivation
    // (`FeedbackRouterGoodZoneTests.entersGoodZoneOnce` has the full
    // frame-by-frame version this mirrors; nFrameSetup == 5,
    // goodZoneChimeDelayMs == 0, both defaults):
    //
    // Frames 1-4 of this batch (`pendingStreak` 1..4) haven't reached
    // §7.2's N-frame threshold yet, so `confirmedState` is still `nil` and
    // `arrivalAnnounced` is `false` — the beacon plays THROUGH the
    // confirmation window instead of going silent for it, one `.update`
    // per frame.
    //
    // Frame 5 is where `pendingStreak` reaches 5: `confirmedState` becomes
    // `.goodZone` DURING this same `ingest` call. `ingest` runs discrete
    // processing (which fires the entry earcon via `tickAnnouncements`,
    // `goodZoneChimeDelayMs` 0 satisfying its dwell gate at elapsed 0ms)
    // BEFORE the continuous channel (see `ingest(_:at:)`'s own doc
    // comment on that ordering), so within this ONE call the chime
    // (`.play(.enteredGoodZone)`) is necessarily followed by the cut
    // (`.update(nil)`), never the reverse and never split across frames —
    // the atomic arrival.
    let beaconTarget = SonificationTarget(
      errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false)
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)

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

  @Test(
    "a zone transit shorter than the N-frame threshold neither cuts the beacon nor chimes (overshoot-flicker fix)"
  )
  func subThresholdZoneTransitNeitherCutsNorChimes() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // NEW regression (overshoot-flicker fix): Setup's nFrameSetup == 5, so
    // 4 consecutive in-zone frames is the largest "transit" that CANNOT
    // reconfirm `confirmedState` to `.goodZone` — modeling a subject
    // swinging through center on the way to settling elsewhere (4 frames
    // of near-zero error, then back out of the dead zone) rather than
    // actually arriving. Pre-atomic-arrival, the continuous channel
    // decided beacon-vs-silence off the RAW per-frame `framing.inDeadZone`
    // flag, so those 4 in-zone frames would have blinked the tone off and
    // back on. Atomic arrival's `arrivalAnnounced` gate instead reads
    // `confirmedState == .goodZone` — the N-frame-CONFIRMED state, which
    // never changes here — so the beacon keeps sending an ACTIVE target
    // through the whole transit (never `nil`), and `enteredGoodZone` never
    // fires, because the placement never actually got confirmed. This is
    // the "Side benefit" `updateContinuousSonification`'s doc comment
    // calls out: "raw-frame zone transits during overshoots no longer
    // blink the tone off."
    await router.ingest(framingErrorOutput(errorX: 0.2), at: t0)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 33), count: 4)
    await router.ingest(framingErrorOutput(errorX: 0.2), at: t0.plus(ms: 165))

    let updates = await updateArguments(audio)
    #expect(updates.count == 6, "one update per ingested frame, got \(updates)")
    #expect(
      updates.allSatisfy { $0 != nil },
      "beacon must never cut to nil mid-transit, got \(updates)")
    #expect(await audio.playedEvents().isEmpty, "sub-threshold transit must not chime")
  }

  /// Extracts the arguments of every `.update` call, preserving nil-ness:
  /// outer array element per call, inner optional is the sent target.
  private func updateArguments(_ audio: MockAudioRenderer) async -> [SonificationTarget?] {
    await audio.calls.compactMap { call in
      if case .update(let target) = call { return .some(target) } else { return nil }
    }
  }
}
