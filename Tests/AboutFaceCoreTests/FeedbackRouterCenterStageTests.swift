import Testing

@testable import AboutFaceCore

/// §12.5 Center Stage awareness (`FeedbackRouter+CenterStage.swift`,
/// `FeedbackRouter+AnnouncementPayload.swift`) — the rising/falling-edge
/// latch, the beacon suppression folded into
/// `updateContinuousSonification`'s resolve-then-send shape
/// (`FeedbackRouter+Continuous.swift`), spoken-framing suppression, and the
/// §7.3 recovery carve-out. Split into its own suite for the same reason
/// every other `FeedbackRouter*Tests.swift` file gives: this is a
/// self-contained addition, not a modification of behavior already pinned
/// down elsewhere.
///
/// `heartbeatStillFiresWhileCenterStageActive` below is referenced BY NAME
/// from `tickGoodZone`'s own doc comment (`FeedbackRouter+Announcements
/// .swift`) as the regression test for the "easy and silent" bug that
/// comment calls out — do not rename it without updating that comment too.
struct FeedbackRouterCenterStageTests {

  // MARK: - Beacon suppression (continuous channel)

  @Test(
    "activating mid-stream cuts a playing beacon exactly once, and it stays cut until deactivated"
  )
  func activatingMidStreamCutsBeaconOnceAndStaysCutUntilDeactivated() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    // A live beacon: an ordinary out-of-dead-zone frame sends a real target
    // (the beacon branch has no N-frame gate of its own — see
    // `updateContinuousSonification`'s own doc comment).
    let errorOutput = framingErrorOutput(errorX: 0.5)
    await router.ingest(errorOutput, at: t0)
    let beaconTarget = SonificationTarget(
      errorX: 0.5, errorY: 0, distanceError: 0, inDeadZone: false)
    #expect(await audio.calls.last == .update(beaconTarget))

    // Rising edge, mid-stream: `setCenterStageActive` never itself touches
    // `audio` (it only ever calls `fire` for the spoken notice) — the cut
    // is a consequence of the NEXT `ingest`, not of this call.
    await router.setCenterStageActive(true, at: t0.plus(ms: 1))
    #expect(
      await audio.calls.last == .update(beaconTarget),
      "setCenterStageActive itself must not touch the audio renderer")

    await router.ingest(errorOutput, at: t0.plus(ms: 33))
    #expect(await audio.calls.last == .update(nil))
    let callCountAfterCut = await audio.calls.count

    // Holding the same out-of-zone condition across many more frames must
    // neither resend the cut nor resume the beacon.
    await router.ingest(errorOutput, at: t0.plus(ms: 66))
    await router.ingest(errorOutput, at: t0.plus(ms: 100))
    #expect(await audio.calls.count == callCountAfterCut)

    // Falling edge: the beacon resumes on the very next ingest.
    await router.setCenterStageActive(false, at: t0.plus(ms: 101))
    await router.ingest(errorOutput, at: t0.plus(ms: 133))
    #expect(await audio.calls.last == .update(beaconTarget))
  }

  @Test("gaze trim still reaches the renderer under Center Stage, once confirmed in the good zone")
  func gazeTrimStillFlowsUnderCenterStageInConfirmedGoodZone() async {
    var config = Config.defaults
    config.audio.gazeTrim.enabled = true
    config.targetFraming.neutralYawDegrees = 5
    config.targetFraming.neutralPitchDegrees = -5
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, config: config, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    // yawDeviation = 15 - 5 = 10, pitchDeviation = -5 - (-5) = 0.
    let output = makeOutput(
      signalState: .ok, inDeadZone: true, gazeOnCamera: true, yaw: 15, pitch: -5)
    await ingestRepeated(router, output, at: t0.plus(ms: 1), count: 5)

    let calls = await audio.calls
    guard case .update(let target?) = calls.last else {
      Issue.record("expected a trim SonificationTarget update, got \(calls)")
      return
    }
    #expect(target.gazeTrimActive)
    #expect(target.yawDeviationDegrees == 10)
    #expect(target.pitchDeviationDegrees == 0)

    // Confirms this trim target is not merely riding along on an
    // unsuppressed arrival — the entry chime/phrase are suppressed under
    // Center Stage, so the only speech is the rising-edge notice itself.
    #expect(await audio.playedEvents().isEmpty)
    #expect(await speech.calls == [.speak(Lexicon.State.centerStageOn)])
  }

  // MARK: - Spoken framing suppression

  @Test("a framing-error episode speaks nothing while active, and speaks normally once inactive")
  func framingErrorSpeechSuppressedWhileActiveThenNormalAfterDeactivation() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    let errorOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, errorOutput, at: t0.plus(ms: 1), count: 5)
    await router.ingest(errorOutput, at: t0.plus(ms: 801))  // 800ms dwell fires

    // Only the rising-edge notice was spoken — the framing instruction
    // itself ("Left.") is suppressed under Center Stage.
    #expect(await speech.calls == [.speak(Lexicon.State.centerStageOn)])

    // A fresh episode after deactivation speaks normally: pass back through
    // the good zone to re-arm the per-episode dwell latch (`confirmedState`
    // change resets it unconditionally — see `onConfirmedStateChanged`),
    // then re-enter a framing error with Center Stage now off.
    await router.setCenterStageActive(false, at: t0.plus(ms: 900))
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 901), count: 5)
    await ingestRepeated(router, errorOutput, at: t0.plus(ms: 950), count: 5)
    await router.ingest(errorOutput, at: t0.plus(ms: 1751))  // 800ms dwell from 950

    #expect(await speech.calls.contains(.speak(Lexicon.Instruction.left)))
  }

  // MARK: - §6.1 heartbeat regression (see this file's own doc comment)

  @Test(
    "holding a good-zone episode entered while Center Stage was active still fires the §6.1 heartbeat on cadence"
  )
  func heartbeatStillFiresWhileCenterStageActive() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1), count: 5)

    // Arrival itself is silent under Center Stage — no chime, no
    // "Centered." — which is exactly the condition under which the
    // heartbeat's own scheduling (`nextHeartbeatAt`) is easiest to skip by
    // accident (see `tickGoodZone`'s doc comment,
    // `FeedbackRouter+Announcements.swift`).
    #expect(await audio.playedEvents().isEmpty)
    #expect(await speech.calls == [.speak(Lexicon.State.centerStageOn)])

    // Holding the episode across the 7s heartbeat cadence must still
    // produce the liveness tick — the regression this test exists to catch.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 6999))
    #expect(await audio.playedEvents().isEmpty)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 7001))
    #expect(await audio.playedEvents() == [.livenessHeartbeat])
  }

  // MARK: - §7.3 recovery interaction

  @Test(
    "face-lost recovery into a framing error speaks recovery, not silence, while Center Stage is active"
  )
  func faceLostRecoveryIntoFramingErrorSpeaksRecoveredWhileActive() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1501))  // rung 1
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5001))  // rung 2: "No face."
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_001))  // rung 3: STOP
    #expect(await router.isUserLikelyAway() == true)

    // Reacquire straight into a framing error, still under Center Stage.
    await ingestRepeated(
      router, framingErrorOutput(errorX: 0.5), at: t0.plus(ms: 30_101), count: 3)

    #expect(await router.isUserLikelyAway() == false)
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.State.centerStageOn),
        .speak(Lexicon.Instruction.noFace),
        .speak(Lexicon.Instruction.recovered),
      ])
    // swiftlint:enable trailing_comma
  }

  // MARK: - The notice itself: edge latch, silence, rung 3, config gate

  @Test("the notice speaks exactly once per genuine edge, not once per call — both edges speak")
  func noticeSpeaksOncePerEdgeBothDirections() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    await router.setCenterStageActive(true, at: t0.plus(ms: 1))
    await router.setCenterStageActive(true, at: t0.plus(ms: 2))
    #expect(await speech.calls == [.speak(Lexicon.State.centerStageOn)])

    await router.setCenterStageActive(false, at: t0.plus(ms: 3))
    await router.setCenterStageActive(false, at: t0.plus(ms: 4))
    // swiftlint:disable trailing_comma
    #expect(
      await speech.calls == [
        .speak(Lexicon.State.centerStageOn),
        .speak(Lexicon.State.centerStageOff),
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("the notice does not speak while isSilenced")
  func noticeDoesNotSpeakWhileSilenced() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setSilenced(true)
    await router.setCenterStageActive(true, at: t0)

    let speakCalls = (await speech.calls).filter {
      if case .speak = $0 { return true }
      return false
    }
    #expect(speakCalls.isEmpty)
  }

  @Test("the notice does not speak while userLikelyAway (§7.3 rung 3)")
  func noticeDoesNotSpeakWhileUserLikelyAway() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))  // rung 1
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))  // rung 2
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_000))  // rung 3: STOP
    #expect(await router.isUserLikelyAway() == true)

    await router.setCenterStageActive(true, at: t0.plus(ms: 30_001))

    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])
  }

  @Test(
    "centerStageAwarenessEnabled == false suppresses the notice and leaves the beacon/framing behavior untouched"
  )
  func awarenessDisabledActsAsIfCenterStageDidNotExist() async {
    var config = Config.defaults
    config.camera.centerStageAwarenessEnabled = false
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, config: config, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setCenterStageActive(true, at: t0)
    await router.setCenterStageActive(true, at: t0.plus(ms: 1))
    #expect(await speech.calls.isEmpty)

    // Framing beacon and good-zone entry behave exactly as if Center Stage
    // were never toggled: the entry chime AND phrase both fire normally,
    // which is only possible if `centerStageActive` was forced `false`
    // internally regardless of what the caller passed.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 2), count: 5)

    #expect(await audio.playedEvents() == [.enteredGoodZone])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.centered)])
  }
}
