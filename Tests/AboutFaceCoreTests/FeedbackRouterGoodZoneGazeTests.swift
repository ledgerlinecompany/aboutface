import Testing

@testable import AboutFaceCore

/// §7.4 rung 6's redesign (app field finding, 2026-08-02): gaze-off no
/// longer blocks `.goodZone` classification or the `enteredGoodZone`
/// earcon (that regression is covered in `FeedbackRouterGoodZoneTests
/// .gazeOffOnArrivalDoesNotBlockEnteredGoodZone`). Instead, gaze-off is
/// tracked FROM WITHIN a confirmed good-zone episode
/// (`FeedbackRouter.tickGoodZoneGaze(output:at:)`), on the same N-frame
/// (§7.2) + 800ms dwell (§7.1) discipline as any other condition, speaking
/// `Lexicon.Instruction.lookAtCamera` at most once per episode. See
/// `FeedbackCondition.gazeOff`'s doc comment for the full story.
///
/// **Atomic arrival (reviewer fix, 2026-08-02):** every test below enters
/// the good zone via a single `ingestRepeated(..., count: 5)` batch whose
/// 5th frame confirms `.goodZone` AND fires `enteredGoodZone` in the same
/// `ingest` call (`goodZoneChimeDelayMs` default 0 — see
/// `FeedbackRouterGoodZoneTests.entersGoodZoneOnce` for the full
/// frame-by-frame derivation). `entryFireTime` below is therefore always
/// the batch's own instant, not a separate later call — the gaze-off
/// N-frame+800ms timers this file exercises are hand-derived as offsets
/// FROM that instant.
struct FeedbackRouterGoodZoneGazeTests {

  /// `.goodZone`-classifying output with gaze off camera: `inDeadZone:
  /// true` (placement is all that matters for classification now),
  /// `gazeOnCamera: false`.
  private func gazeOffGoodZoneOutput() -> EngineOutput {
    makeOutput(signalState: .ok, inDeadZone: true, gazeOnCamera: false)
  }

  @Test("gaze off held N-frames + 800ms inside the good zone speaks lookAtCamera exactly once")
  func gazeOffInGoodZoneSpeaksOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    let entryFireTime = t0
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    let gazeOff = gazeOffGoodZoneOutput()

    // §7.2 N-frame confirmation: 5 consecutive gaze-off frames, all at the
    // same instant (same idiom the top-level pipeline's own tests use).
    await ingestRepeated(router, gazeOff, at: entryFireTime.plus(ms: 100), count: 5)
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // §7.1 800ms dwell, timed from the CONFIRMATION frame (entry + 100ms).
    // Audio assertions filter to `.play` events (`playedEvents()`) because
    // atomic arrival now interleaves the confirmation-window beacon
    // `.update` calls from the entry above — this test's intent is "did
    // enteredGoodZone fire, exactly once, and nothing else," not the exact
    // interleaving (`FeedbackRouterGoodZoneTests.entersGoodZoneOnce` pins
    // that down separately).
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 100 + 799))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
    #expect(await audio.playedEvents() == [.enteredGoodZone])

    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 100 + 800))
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on) trailing_comma
    // rule forbids one. Format wins (see FeedbackRouter+Announcements.swift
    // for the same disagreement elsewhere in this codebase).
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
      ])
    // swiftlint:enable trailing_comma
    // No AudioEvent for gaze — `Lexicon.swift`'s "tones never mean look."
    #expect(await audio.playedEvents() == [.enteredGoodZone])

    // Continuing to hold gaze off must not refire it.
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 9200))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("gaze recovering mid-dwell resets the gaze dwell, requiring a fresh N-frame + 800ms")
  func gazeRecoveryMidDwellResets() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    let entryFireTime = t0

    let gazeOff = gazeOffGoodZoneOutput()

    // Confirm a gaze-off streak (5 frames at entry+100ms), then recover —
    // gaze back on camera, still placed — well before the 800ms dwell it
    // just started would have elapsed.
    await ingestRepeated(router, gazeOff, at: entryFireTime.plus(ms: 100), count: 5)
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 400))

    // Nothing fires even past where the ORIGINAL (now-reset) dwell would
    // have (100 + 800 = 900ms past entry) — proof the recovery frame
    // actually reset it rather than merely pausing it.
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 950))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // A brand new gaze-off streak, confirmed and dwelled from scratch,
    // still announces exactly once.
    await ingestRepeated(router, gazeOff, at: entryFireTime.plus(ms: 1200), count: 5)
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 1200 + 799))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 1200 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("zone exit and re-entry allows a fresh gaze-off announcement (Setup has no rate limit)")
  func exitAndReentryAllowsFreshGazeAnnouncement() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    let gazeOff = gazeOffGoodZoneOutput()

    // First episode: enter (confirms + fires atomically), confirm + dwell
    // gaze-off, announce once. `lookAtCamera` fires at entry(t0) + 900ms
    // (100ms to confirm the gaze-off streak, then the 800ms dwell).
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    await ingestRepeated(router, gazeOff, at: t0.plus(ms: 100), count: 5)
    await router.ingest(gazeOff, at: t0.plus(ms: 100 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
      ])
    // swiftlint:enable trailing_comma

    // Exit the dead zone (N-frame confirmed) to close the episode, then
    // re-enter shortly after — same tight (100ms) confirm-batch spacing
    // `FeedbackRouterGoodZoneTests.exitResumesPositionalUpdates` uses, so
    // the now-superseded `.framingError` state's OWN 800ms dwell never
    // gets a chance to elapse (and fire "Right.") before the re-entry
    // batch supersedes it — an existing `tickGenericDwell` property (it
    // ticks whatever `confirmedState` currently is, every frame,
    // independent of what the incoming raw frame classifies as), not
    // something new here. `lookAtCamera` fired at t0+900; exit batch
    // starts 100ms later at t0+1000.
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, exitOutput, at: t0.plus(ms: 1000), count: 5)

    // Re-enter: a brand new episode. This batch's 5th frame both
    // reconfirms `.goodZone` (superseding `.framingError`) and fires
    // `enteredGoodZone` atomically, at t0+1100 (another 100ms gap, same
    // spacing as above).
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1100), count: 5)
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
        .speak(Lexicon.Instruction.centered),
      ])
    // swiftlint:enable trailing_comma

    // Gaze off again in the new episode: a fresh announcement is allowed —
    // Setup's `ModeLimits` are both `nil` (§5.1: "no rate limiting beyond
    // the dwell time"), so nothing blocks it. Same 100ms-confirm +
    // 800ms-dwell shape as the first episode, offset from THIS episode's
    // entry fire time (t0+1100).
    await ingestRepeated(router, gazeOff, at: t0.plus(ms: 1200), count: 5)
    await router.ingest(gazeOff, at: t0.plus(ms: 1200 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.lookAtCamera),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("the good-zone heartbeat cadence is unaffected by a gaze-off announcement firing between")
  func heartbeatUnaffectedByGazeAnnouncement() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Confirms `.goodZone` AND fires `enteredGoodZone` (+ seeds
    // `nextHeartbeatAt = t0 + heartbeatIntervalMs`) atomically on the 5th
    // frame — see `FeedbackRouterGoodZoneTests.entersGoodZoneOnce`'s
    // derivation. The heartbeat schedule is therefore seeded from `t0`
    // itself, not a separate later "entered" call.
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    let entryFireTime = t0

    let gazeOff = gazeOffGoodZoneOutput()

    // Gaze-off confirmed + dwelled well before the first 7s heartbeat.
    await ingestRepeated(router, gazeOff, at: entryFireTime.plus(ms: 100), count: 5)
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 100 + 800))
    #expect(await speech.calls.contains(.speak(Lexicon.Instruction.lookAtCamera)))

    // Heartbeats still land at 7s/14s measured from the ENTRY fire time,
    // not shifted by the gaze announcement in between. `.contains`/
    // `.filter` below are membership checks, unaffected by the
    // atomic-arrival beacon `.update` calls interleaved earlier in
    // `audio.calls` — no filtering helper needed for these.
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 6999))
    #expect(!(await audio.calls.contains(.play(.livenessHeartbeat))))

    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 7000))
    await router.ingest(gazeOff, at: entryFireTime.plus(ms: 14000))

    let heartbeatCount = await audio.calls.filter { $0 == .play(.livenessHeartbeat) }.count
    #expect(heartbeatCount == 2)
  }
}
