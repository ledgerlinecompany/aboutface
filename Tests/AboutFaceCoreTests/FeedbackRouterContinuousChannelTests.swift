import Testing

@testable import AboutFaceCore

/// Regression tests for the continuous channel's resolve-and-send shape
/// (app field finding: "if face stops being detected it makes the sound for
/// that but the tone doesn't stop"). The channel must send exactly one of
/// {beacon target, trim target, nil} per frame, deduping nil.
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

  @Test("Dead-zone entry cuts the beacon immediately (nil), before any dwell")
  func zoneEntryCutsImmediately() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.ingest(framingErrorOutput(errorX: 0.2), at: t0)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 33))

    let updates = await updateArguments(audio)
    #expect(
      updates.last != nil && updates.last! == nil,
      "zone entry cuts the beacon at once, got \(updates)")
  }

  /// Extracts the arguments of every `.update` call, preserving nil-ness:
  /// outer array element per call, inner optional is the sent target.
  private func updateArguments(_ audio: MockAudioRenderer) async -> [SonificationTarget?] {
    await audio.calls.compactMap { call in
      if case .update(let target) = call { return .some(target) } else { return nil }
    }
  }
}
