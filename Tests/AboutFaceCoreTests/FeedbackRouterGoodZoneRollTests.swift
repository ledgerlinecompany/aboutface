import Testing

@testable import AboutFaceCore

/// §4 extension, maintainer 2026-08-02: "Agreed, it's part of gaze" — roll
/// gets the SAME in-zone-advisory treatment
/// `FeedbackRouterGoodZoneGazeTests` covers for gaze-off, via a second,
/// fully independent sub-machine (`FeedbackRouter.tickGoodZoneRoll(output:at:)`):
/// its own N-frame (§7.2) + 800ms dwell (§7.1) discipline, its own
/// once-per-episode latch, tracking `!FramingState.headLevel` instead of
/// `!gazeOnCamera`, speaking `Lexicon.Instruction.level` instead of
/// `.lookAtCamera`. See `FeedbackCondition.headTilt`'s doc comment for the
/// full story.
///
/// Same atomic-arrival idiom as `FeedbackRouterGoodZoneGazeTests`: every
/// test below enters the good zone via a single `ingestRepeated(...,
/// count: 5)` batch whose 5th frame confirms `.goodZone` AND fires
/// `enteredGoodZone` in the same `ingest` call (`goodZoneChimeDelayMs`
/// default 0), so `entryFireTime` is always that batch's own instant.
struct FeedbackRouterGoodZoneRollTests {

  /// `.goodZone`-classifying output with a held tilt: `inDeadZone: true`
  /// (placement is all that matters for classification — roll never gates
  /// it, same as gaze), `headLevel: false`.
  private func headTiltGoodZoneOutput() -> EngineOutput {
    makeOutput(signalState: .ok, inDeadZone: true, headLevel: false)
  }

  @Test("head tilt held N-frames + 800ms inside the good zone speaks level exactly once")
  func headTiltInGoodZoneSpeaksOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    let entryFireTime = t0
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    let tilted = headTiltGoodZoneOutput()

    // §7.2 N-frame confirmation: 5 consecutive tilted frames.
    await ingestRepeated(router, tilted, at: entryFireTime.plus(ms: 100), count: 5)
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // §7.1 800ms dwell, timed from the confirmation frame (entry + 100ms).
    await router.ingest(tilted, at: entryFireTime.plus(ms: 100 + 799))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
    #expect(await audio.playedEvents() == [.enteredGoodZone])

    await router.ingest(tilted, at: entryFireTime.plus(ms: 100 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma
    // No AudioEvent for a tilt advisory — same "tones never mean look/tilt"
    // contract gaze-off keeps.
    #expect(await audio.playedEvents() == [.enteredGoodZone])

    // Continuing to hold the tilt must not refire it.
    await router.ingest(tilted, at: entryFireTime.plus(ms: 9200))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("head leveling mid-dwell resets the tilt dwell, requiring a fresh N-frame + 800ms")
  func headTiltRecoveryMidDwellResets() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    let entryFireTime = t0

    let tilted = headTiltGoodZoneOutput()

    // Confirm a tilt streak (5 frames at entry+100ms), then recover — head
    // level again, still placed — well before the 800ms dwell it just
    // started would have elapsed.
    await ingestRepeated(router, tilted, at: entryFireTime.plus(ms: 100), count: 5)
    await router.ingest(goodZoneOutput(), at: entryFireTime.plus(ms: 400))

    // Nothing fires even past where the ORIGINAL (now-reset) dwell would
    // have (100 + 800 = 900ms past entry).
    await router.ingest(tilted, at: entryFireTime.plus(ms: 950))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // A brand new tilt streak, confirmed and dwelled from scratch, still
    // announces exactly once.
    await ingestRepeated(router, tilted, at: entryFireTime.plus(ms: 1200), count: 5)
    await router.ingest(tilted, at: entryFireTime.plus(ms: 1200 + 799))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
    await router.ingest(tilted, at: entryFireTime.plus(ms: 1200 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("zone exit and re-entry allows a fresh head-tilt announcement (Setup has no rate limit)")
  func exitAndReentryAllowsFreshHeadTiltAnnouncement() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    let tilted = headTiltGoodZoneOutput()

    // First episode: enter, confirm + dwell tilt, announce once.
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)
    await ingestRepeated(router, tilted, at: t0.plus(ms: 100), count: 5)
    await router.ingest(tilted, at: t0.plus(ms: 100 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma

    // Exit the dead zone to close the episode, then re-enter shortly after
    // — same tight (100ms) confirm-batch spacing
    // `FeedbackRouterGoodZoneGazeTests.exitAndReentryAllowsFreshGazeAnnouncement`
    // uses. `level` fired at t0+900; exit batch starts 100ms later.
    let exitOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, exitOutput, at: t0.plus(ms: 1000), count: 5)

    // Re-enter: a brand new episode, entering + firing atomically at
    // t0+1100.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1100), count: 5)
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
        .speak(Lexicon.Instruction.centered),
      ])
    // swiftlint:enable trailing_comma

    // Tilted again in the new episode: a fresh announcement is allowed —
    // Setup's `ModeLimits` are both `nil` (§5.1).
    await ingestRepeated(router, tilted, at: t0.plus(ms: 1200), count: 5)
    await router.ingest(tilted, at: t0.plus(ms: 1200 + 800))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
        .speak(Lexicon.Instruction.centered), .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("Monitor mode: a held tilt never speaks (no AudioEvent, no Monitor-register phrase)")
  func monitorModeNeverSpeaksHeadTilt() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    let tilted = headTiltGoodZoneOutput()

    // Monitor's N-frame threshold is 3 (`FeedbackConfig.defaults.nFrameMonitor`
    // — see `FeedbackRouterRateLimitTests`' own comment to this effect).
    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 3)
    let entryFireTime = t0
    #expect(await audio.playedEvents() == [.enteredGoodZone])
    #expect(await speech.calls == [])  // Monitor: earcon-only entry, no `centered` speech.

    await ingestRepeated(router, tilted, at: entryFireTime.plus(ms: 100), count: 3)
    await router.ingest(tilted, at: entryFireTime.plus(ms: 100 + 800))
    // Held well past where a fresh dwell-fire attempt could land, in case
    // the advisory were (incorrectly) speaking on some later frame too.
    await router.ingest(tilted, at: entryFireTime.plus(ms: 5000))

    // `tickGoodZoneRoll`'s `phrase` resolves to `nil` in Monitor mode and
    // `.headTilt` carries no `AudioEvent` — `fire`'s no-op short-circuit
    // means this never even consumes a rate-limit slot, but the observable
    // contract either way is: nothing spoken, nothing played beyond the
    // entry earcon.
    #expect(await speech.calls == [])
    #expect(await audio.playedEvents() == [.enteredGoodZone])
  }

  @Test("gaze-off and head-tilt are independent: whichever confirms first speaks first, both land")
  func gazeAndRollAdvisoriesAreIndependent() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 5)  // confirms + fires atomically
    let entryFireTime = t0
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])

    // Both problems at once: gaze off camera AND head tilted, in the same
    // frames — the two sub-machines are independent, so both should
    // eventually announce, each on its own N-frame+dwell schedule (which
    // happen to be identical here, so they land on the SAME confirmed
    // frame — `tickGoodZoneGaze` runs textually first in `tickGoodZone`,
    // so it speaks first when both complete simultaneously).
    let both = makeOutput(signalState: .ok, inDeadZone: true, gazeOnCamera: false, headLevel: false)

    await ingestRepeated(router, both, at: entryFireTime.plus(ms: 100), count: 5)
    await router.ingest(both, at: entryFireTime.plus(ms: 100 + 800))

    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.centered),
        .speak(Lexicon.Instruction.lookAtCamera),
        .speak(Lexicon.Instruction.level),
      ])
    // swiftlint:enable trailing_comma
    // Neither advisory has an AudioEvent.
    #expect(await audio.playedEvents() == [.enteredGoodZone])
  }
}
