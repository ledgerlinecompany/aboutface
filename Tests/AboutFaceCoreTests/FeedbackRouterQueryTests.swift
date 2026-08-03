import Testing

@testable import AboutFaceCore

/// §5.3 Query mode and §8 repeat-last, exercised through the real
/// `FeedbackRouter` (mock renderers, no live camera — same conventions as
/// `FeedbackRouterRateLimitTests`/`FeedbackRouterTestSupport.swift`).
struct FeedbackRouterQueryTests {

  // MARK: - performQuery(at:)

  @Test("performQuery speaks a composed summary built from the recent ingest burst")
  func performQuerySpeaksComposedSummary() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    // Monitor mode: entering the good zone plays an earcon but never
    // speaks (§5.2 "earcons only by default") — Setup mode's own
    // `Instruction.centered` announcement on good-zone entry would
    // otherwise be a second, unrelated `.speak` call muddying this
    // assertion.
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    let spoken = await router.performQuery(at: t0)

    #expect(spoken != nil)
    let calls = await speech.calls
    #expect(calls == [.speak(spoken!)])
  }

  @Test("performQuery no-ops (speaks nothing) before any frame has been ingested")
  func performQueryNoOpsWithEmptyBurst() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)

    let spoken = await router.performQuery(at: ContinuousClock().now)

    #expect(spoken == nil)
    #expect(await speech.calls.isEmpty)
  }

  @Test("performQuery bypasses the Monitor rate limit even immediately after another announcement")
  func performQueryBypassesMonitorRateLimit() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    // Consume the Monitor global rate-limit budget with an ordinary
    // announcement (§5.2's 1/20s limiter).
    await ingestRepeated(router, noSignalOutput(), at: t0, count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))
    #expect(await audio.calls.contains(.play(.noSignal)))

    // A query fired 1ms later — deep inside the 20s window — must still
    // speak: §5.3 says "on demand, any mode, any time," and the task brief
    // frames Query as a user-initiated pull exempt from Monitor's
    // discretionary throttle, the same way the heartbeat/face-lost ladder
    // already are.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 801), count: 3)
    let spoken = await router.performQuery(at: t0.plus(ms: 801))

    #expect(spoken != nil)
  }

  @Test("performQuery interrupts any in-flight utterance (same speak(_:) call, no extra stop)")
  func performQueryInterruptsInFlightSpeech() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    _ = await router.performQuery(at: t0)

    // §6.3: `SpeechRendering.speak(_:)` conformers "MUST preempt, not
    // queue" — `performQuery` relies on that contract rather than calling
    // `stopSpeaking()` itself, so the mock's call log should show only
    // `.speak`, never an extra `.stopSpeaking`.
    let calls = await speech.calls
    #expect(!calls.contains(.stopSpeaking))
  }

  @Test("performQuery respects manual silence — speaks nothing while isSilenced")
  func performQueryRespectsSilence() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    await router.setSilenced(true)
    let spoken = await router.performQuery(at: t0.plus(ms: 10))

    #expect(spoken == nil)
    // `setSilenced(true)` itself calls `speech.stopSpeaking()` (§7.5) — that
    // is expected and unrelated to Query; what matters here is that the
    // silenced `performQuery` call produced no NEW `.speak`.
    #expect(
      !(await speech.calls).contains {
        if case .speak = $0 { return true }
        return false
      })
  }

  @Test("performQuery honors problemsOnly from FeedbackConfig")
  func performQueryHonorsProblemsOnlyConfig() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    var feedbackConfig = FeedbackConfig.defaults
    feedbackConfig.query.problemsOnly = true
    let router = FeedbackRouter(
      audio: audio, speech: speech, feedbackConfig: feedbackConfig, mode: .setup)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    let spoken = await router.performQuery(at: t0)

    #expect(spoken == Lexicon.State.allClear)
  }

  @Test("performQuery's burst is bounded by Config.feedback.query.burstFrameCount")
  func performQueryBurstIsBoundedByConfig() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    var feedbackConfig = FeedbackConfig.defaults
    feedbackConfig.query.burstFrameCount = 3
    let router = FeedbackRouter(
      audio: audio, speech: speech, feedbackConfig: feedbackConfig, mode: .setup)
    let t0 = ContinuousClock().now

    // 2 bad frames, then 3 good frames — with a 3-frame burst window, only
    // the good frames should still be in the ring by the time performQuery
    // runs, so framing reads "centered," not out-of-zone.
    await ingestRepeated(router, framingErrorOutput(), at: t0, count: 2)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1), count: 3)
    let spoken = await router.performQuery(at: t0.plus(ms: 1))

    #expect(spoken != nil)
    #expect(spoken!.text.contains(Lexicon.State.centered.text))
    #expect(!spoken!.text.contains(Lexicon.State.left.text))
    #expect(!spoken!.text.contains(Lexicon.State.right.text))
  }

  // MARK: - repeatLastAnnouncement()

  @Test("repeatLastAnnouncement re-speaks the last phrase fire(...) actually spoke")
  func repeatLastAnnouncementRepeatsFiredPhrase() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    // Drive a real dwell-fired Setup-mode announcement: framing error, out
    // of the dead zone, dwelled 800ms. `error.x > 0` means "subject right of
    // target," corrected by moving left (`FeedbackRouter
    // +Announcements.swift`'s `framingInstruction`'s own sign convention).
    await ingestRepeated(router, framingErrorOutput(errorX: 0.5), at: t0, count: 5)
    await router.ingest(framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 800))
    let firstCalls = await speech.calls
    #expect(firstCalls == [.speak(Lexicon.Instruction.left)])

    await router.repeatLastAnnouncement()

    let allCalls = await speech.calls
    #expect(allCalls == [.speak(Lexicon.Instruction.left), .speak(Lexicon.Instruction.left)])
  }

  @Test("repeatLastAnnouncement can repeat a Query summary")
  func repeatLastAnnouncementRepeatsQuerySummary() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    let spoken = await router.performQuery(at: t0)
    await router.repeatLastAnnouncement()

    let calls = await speech.calls
    #expect(calls == [.speak(spoken!), .speak(spoken!)])
  }

  @Test("repeatLastAnnouncement no-ops before anything has ever been spoken")
  func repeatLastAnnouncementNoOpsWithNothingSpokenYet() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)

    await router.repeatLastAnnouncement()

    #expect(await speech.calls.isEmpty)
  }

  @Test("repeatLastAnnouncement bypasses the Monitor rate limit")
  func repeatLastAnnouncementBypassesMonitorRateLimit() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, noSignalOutput(), at: t0, count: 3)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))
    #expect(await audio.calls.contains(.play(.noSignal)))
    // Nothing SPOKEN yet (`.noSignal` is an audio-only event in this
    // codebase's Monitor-mode payload table), so seed `lastSpokenPhrase`
    // with a real Query first.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 801), count: 3)
    let spoken = await router.performQuery(at: t0.plus(ms: 801))
    #expect(spoken != nil)

    // Immediately repeat — well inside the 20s/3min Monitor windows.
    await router.repeatLastAnnouncement()

    let calls = await speech.calls
    #expect(calls == [.speak(spoken!), .speak(spoken!)])
  }

  @Test("repeatLastAnnouncement respects manual silence")
  func repeatLastAnnouncementRespectsSilence() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, goodZoneOutput(), at: t0, count: 10)
    _ = await router.performQuery(at: t0)
    await router.setSilenced(true)
    await router.repeatLastAnnouncement()

    // Only the original Query `.speak` call — `setSilenced(true)`'s own
    // `.stopSpeaking()` (§7.5) is a separate, expected call, but the
    // silenced `repeatLastAnnouncement()` must not add a SECOND `.speak`.
    let speakCalls = (await speech.calls).filter {
      if case .speak = $0 { return true }
      return false
    }
    #expect(speakCalls.count == 1)
  }
}
