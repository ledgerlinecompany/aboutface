import Testing

@testable import AboutFaceCore

/// §7.3's ladder must measure CONTINUOUS absence, not time since the face-lost
/// state was confirmed.
///
/// Maintainer field finding, 2026-08-08, during convergence: the face-lost
/// earcon *"can fire even though you've already been found and the tone is
/// resumed."* The continuous channel is deliberately not N-frame gated (§6.2
/// keeps the correction loop real-time), so a flickering detection resumes the
/// beacon on every good frame — while the confirmed state stays `.faceLost`,
/// because no run of good frames is long enough to re-confirm, and its timer
/// keeps counting from the original confirmation. The user hears "I can see
/// you" and "I have lost you" at the same moment.
struct FeedbackRouterFlickerTests {
  /// A detection that keeps flickering back must not produce a face-lost
  /// earcon, however long the flickering goes on: the app has never actually
  /// been without a face for the rung's full delay.
  @Test("A flickering detection never fires the face-lost earcon")
  func flickeringNeverFiresRungOne() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    // Confirm face-lost, then flicker: a good frame every 300ms, which is
    // under Setup's 500ms rung-1 delay but far too sparse to re-confirm
    // (nFrameSetup is 5 consecutive frames).
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    var elapsed = 100
    for _ in 0..<20 {
      await router.ingest(goodZoneOutput(), at: t0.plus(ms: elapsed))
      elapsed += 300
      await router.ingest(faceLostOutput(), at: t0.plus(ms: elapsed))
      elapsed += 100
    }

    #expect(!(await audio.playedEvents().contains(.faceLost)))
  }

  /// The fix must not blunt the real alarm: a genuine, uninterrupted absence
  /// still escalates exactly as §7.3 requires.
  @Test("An uninterrupted absence still fires the ladder on schedule")
  func genuineAbsenceStillEscalates() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))
    #expect(await audio.playedEvents().contains(.faceLost))

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5100))
    #expect(await speech.calls.contains(.speak(Lexicon.Instruction.noFace)))

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_100))
    #expect(await router.isUserLikelyAway() == true)
  }

  /// A single good frame partway through a long absence restarts the clock —
  /// the app saw someone, so it cannot honestly call them away moments later.
  @Test("One frame with a face restarts the absence clock")
  func oneGoodFrameRestartsTheClock() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    // Seen at 400ms, so the 500ms rung-1 delay cannot elapse by 600ms.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 400))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))
    #expect(!(await audio.playedEvents().contains(.faceLost)))

    // But 500ms after THAT sighting, it fires.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 950))
    #expect(await audio.playedEvents().contains(.faceLost))
  }
}
