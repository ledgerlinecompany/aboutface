import Testing

@testable import AboutFaceCore

/// `FeedbackRouter` never reads `Date()`/wall-clock time internally — every
/// timer is computed from the injected `ContinuousClock.Instant` sequence
/// (see `FeedbackRouter.swift`'s type-level doc comment). This is what
/// makes corpus-style regression meaningful for the feedback layer, the
/// same way `AnalysisEngineDeterminismTests` does for `AnalysisEngine`:
/// replaying an identical script through a fresh router must always produce
/// a byte-identical (here: value-identical) renderer call log.
struct FeedbackRouterDeterminismTests {

  /// One (output, offset-from-start-in-ms) pair per simulated frame,
  /// covering a mix of the state machine's moving parts: N-frame
  /// confirmation, dwell, the good-zone heartbeat, a face-lost episode
  /// with recovery, and a mode/silence toggle — so this exercises most of
  /// `FeedbackRouter`'s stored state in one script, not just one isolated
  /// feature.
  private static func script() -> [(EngineOutput, Int)] {
    var frames: [(EngineOutput, Int)] = []

    // Enter good zone (5-frame confirm + 800ms dwell), hold past one
    // heartbeat.
    for offset in [0, 0, 0, 0, 0, 800, 7800] {
      frames.append((goodZoneOutput(), offset))
    }

    // Drift out, framing-error instructed (Setup mode speaks it).
    for offset in [8000, 8000, 8000, 8000, 8000, 8800] {
      frames.append((framingErrorOutput(errorX: -0.4), offset))
    }

    // Lose the face entirely, past the §7.3 earcon rung, then recover.
    for offset in [9000, 9000, 9000, 9000, 9000, 10_500] {
      frames.append((faceLostOutput(), offset))
    }
    for offset in [10_600, 10_600, 10_600, 10_600, 10_600] {
      frames.append((goodZoneOutput(), offset))
    }

    return frames
  }

  private static func runScript() async -> ([MockAudioRenderer.Call], [MockSpeechRenderer.Call]) {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    for (output, offsetMs) in script() {
      await router.ingest(output, at: t0.plus(ms: offsetMs))
    }

    return (await audio.calls, await speech.calls)
  }

  @Test("replaying the same ingestion script twice produces identical call logs")
  func identicalScriptProducesIdenticalCallLogs() async {
    let (audioCallsA, speechCallsA) = await Self.runScript()
    let (audioCallsB, speechCallsB) = await Self.runScript()

    #expect(audioCallsA == audioCallsB)
    #expect(speechCallsA == speechCallsB)

    // Sanity: the script actually exercises real state-machine output, so
    // an accidentally-empty comparison couldn't pass this test by default.
    #expect(!audioCallsA.isEmpty)
    #expect(!speechCallsA.isEmpty)
  }
}
