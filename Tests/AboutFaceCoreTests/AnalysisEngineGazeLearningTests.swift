import CoreGraphics
import CoreMedia
import Testing

@testable import AboutFaceCore

/// The §13 Phase 5 capture-free gaze baseline
/// (`AnalysisEngine+GazeBaseline.swift`): a slow EMA over (yaw, pitch) that
/// backs `FramingState.gazeOnCamera` WITHOUT requiring "capture current
/// position as target" (§4 extension) first — the maintainer's "blind users
/// will be hesitant to capture positioning they don't know is right" and
/// §13's "Config.default MUST be genuinely usable with zero calibration."
///
/// All frames here are positionally centered (`inZone: true` by default —
/// zero horizontal/vertical/distance error against `Config.defaults`), so
/// `FramingState.inDeadZone` latches `true` on frame one in every test that
/// doesn't deliberately set `inZone: false`, isolating what's under test to
/// the gaze-baseline eligibility/adaptation/clamp logic itself, not the
/// positional dead-zone latch (already covered by `AnalysisEngineTests`).
struct AnalysisEngineGazeLearningTests {

  // MARK: - Fixture builders

  /// A `RawFaceObservation` at a given egocentric pitch/yaw, positioned
  /// either inside or outside `Config.defaults`' positional dead zone.
  /// `inZone: true` places the eye midpoint and interocular distance
  /// exactly on `Config.defaults.targetFraming` (zero error on every
  /// axis); `inZone: false` moves the eye midpoint far enough off-center
  /// (egocentric X ≈ 0.945 vs. target 0.50) that the horizontal dead-zone
  /// entry threshold (0.06) is blown regardless of smoothing.
  private func observation(
    pitchEgocentric: Float,
    yawEgocentric: Float = 0,
    confidence: Float = 0.9,
    inZone: Bool = true
  ) -> RawFaceObservation {
    let (leftX, rightX): (CGFloat, CGFloat) = inZone ? (0.445, 0.555) : (0.0, 0.11)
    return RawFaceObservation(
      boundingBox: CGRect(x: 0.4, y: 0.47, width: 0.2, height: 0.3),
      eyePoints: [CGPoint(x: leftX, y: 0.62), CGPoint(x: rightX, y: 0.62)],
      // notMirrored negates both yaw and pitch (`egocentricPose(raw:mirror:)`).
      yaw: -yawEgocentric,
      pitch: -pitchEgocentric,
      roll: 0,
      confidence: confidence,
      faceCount: 1
    )
  }

  private func capturedFrame(atSeconds seconds: Double) -> CapturedFrame {
    CapturedFrame(
      pixelBuffer: gradientPixelBuffer(),
      timestamp: CMTime(seconds: seconds, preferredTimescale: 600),
      mirrorState: .notMirrored
    )
  }

  // MARK: - Zero-capture path (THE regression that matters)

  @Test("Zero-capture defaults: gaze reads meaningfully once the baseline seeds from behavior")
  func zeroCaptureSeedsFromBehaviorAndTracksIt() async throws {
    // Config.defaults: no capture (neutral*Degrees == 0), learning enabled.
    // A stable pitch +30 pose (the "camera sits below eyeline" case field
    // testing found) held across several in-zone frames.
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(pitchEgocentric: 30),
      observation(pitchEgocentric: 30),
      observation(pitchEgocentric: 30),
      observation(pitchEgocentric: 30),
      // A sharp, sustained deviation — the second-monitor-glance analog
      // (§14 clip 11's field finding, cited in `AnalysisEngineGazeBaselineTests`).
      observation(pitchEgocentric: 0),
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    // Frame 0: unseeded yet (fallback to the static neutral, 0), so this
    // exact frame reads "off camera" — not asserted, just documented: the
    // seed happens ON this frame, for frame 1 onward to read.
    _ = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 0))

    // Frames 1-3: baseline is seeded at 30 and the pose hasn't moved, so it
    // reads on-camera with zero calibration ever having happened.
    for index in 1...3 {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      #expect(output.framing?.gazeOnCamera == true, "frame \(index)")
    }

    // Frame 4: the deviation is judged against the baseline AS IT STOOD
    // BEFORE this frame (adaptation lags comparison by one frame — see
    // `AnalysisEngine+GazeBaseline.swift`'s doc comment) — so a SHARP
    // deviation is caught immediately, not gradually accepted.
    let deviated = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 4))
    #expect(deviated.framing?.gazeOnCamera == false)
  }

  // MARK: - Adaptation speed (hand-derived EMA)

  @Test("Baseline follows a sustained pose shift at the configured time constant")
  func adaptationFollowsTimeConstant() async throws {
    var config = Config.defaults
    config.gaze.baselineAdaptationSeconds = 4  // tau = 4s

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(pitchEgocentric: 30),  // t=0: seeds at 30
      observation(pitchEgocentric: 36),  // t=1: step to 36, held
      observation(pitchEgocentric: 36),  // t=2
      observation(pitchEgocentric: 36),  // t=3
      observation(pitchEgocentric: 36),  // t=4
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    // alpha = deltaSeconds / tau = 1/4 = 0.25 at every 1s step.
    // seed_0 = 30 (no blend on the seeding frame itself)
    // b_1 = 0.25*36 + 0.75*30   = 31.5
    // b_2 = 0.25*36 + 0.75*31.5 = 32.625
    // b_3 = 0.25*36 + 0.75*32.625 = 33.46875
    // b_4 = 0.25*36 + 0.75*33.46875 = 34.1015625
    let expected: [Float] = [30, 31.5, 32.625, 33.46875, 34.1015625]
    let tolerance: Float = 1e-4

    for (index, expectedPitch) in expected.enumerated() {
      _ = try await engine.process(capturedFrame(atSeconds: Double(index)))
      let baseline = await engine.learnedGazeBaseline()
      let pitch = try #require(baseline.pitchDegrees)
      #expect(
        abs(pitch - expectedPitch) < tolerance,
        "frame \(index): expected \(expectedPitch), got \(pitch)")
    }
  }

  // MARK: - Clamp

  @Test("Learned baseline cannot wander past baselineClampDegrees from its seed")
  func baselineClampsAtConfiguredDistanceFromSeed() async throws {
    var config = Config.defaults
    config.gaze.baselineAdaptationSeconds = 1  // tau = 1s
    config.gaze.baselineClampDegrees = 25
    // A deviation of exactly seed+40 vs. a clamped baseline of seed+25
    // leaves a 15° gap — equal to the DEFAULT maxPitchDegrees, an
    // ambiguous boundary (`<=` reads as on-camera). Use a tighter
    // threshold here so the assertion is unambiguous.
    config.gaze.maxPitchDegrees = 12

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(pitchEgocentric: 30),  // t=0: seeds at 30
      observation(pitchEgocentric: 70),  // t=10: seed+40, big delta -> alpha saturates at 1
      observation(pitchEgocentric: 70),  // t=20: held; baseline already clamped
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    _ = try await engine.process(capturedFrame(atSeconds: 0))
    _ = try await engine.process(capturedFrame(atSeconds: 10))
    let afterFirstJump = await engine.learnedGazeBaseline()
    // blended = 1*70 + 0*30 = 70, clamped to seed(30) + 25 = 55.
    #expect(afterFirstJump.pitchDegrees == 55)

    let holding = try await engine.process(capturedFrame(atSeconds: 20))
    // gazeOnCamera for THIS frame reads the baseline from the previous
    // frame (55, not a fresh unclamped 70): |70 - 55| = 15 > maxPitch(12).
    #expect(holding.framing?.gazeOnCamera == false)

    let stillClamped = await engine.learnedGazeBaseline()
    #expect(stillClamped.pitchDegrees == 55, "stops at seed+25, does not keep climbing toward 70")
  }

  // MARK: - Capture precedence

  @Test("Nonzero captured neutrals seed the baseline exactly, at construction")
  func captureSeedsBaselineExactlyOnInit() async throws {
    var config = Config.defaults
    config.targetFraming.neutralYawDegrees = 20
    config.targetFraming.neutralPitchDegrees = 10
    let engine = AnalysisEngine(backend: ScriptedBackend([]), config: config)

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.yawDegrees == 20)
    #expect(baseline.pitchDegrees == 10)
  }

  @Test("updateConfig with changed nonzero captured neutrals re-seeds the baseline")
  func updateConfigWithChangedCaptureReseeds() async throws {
    var config = Config.defaults
    config.targetFraming.neutralYawDegrees = 20
    config.targetFraming.neutralPitchDegrees = 10
    let engine = AnalysisEngine(backend: ScriptedBackend([]), config: config)

    var recaptured = config
    recaptured.targetFraming.neutralYawDegrees = 5
    recaptured.targetFraming.neutralPitchDegrees = -5
    await engine.updateConfig(recaptured)

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.yawDegrees == 5)
    #expect(baseline.pitchDegrees == -5)
  }

  @Test("updateConfig with UNCHANGED captured neutrals does not reseed (e.g. an unrelated slider)")
  func updateConfigWithUnchangedCaptureDoesNotReseed() async throws {
    var config = Config.defaults
    config.targetFraming.neutralPitchDegrees = 30  // captured
    config.gaze.baselineAdaptationSeconds = 1

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(pitchEgocentric: 30),  // t=0: establishes a cadence reference; baseline stays 30
      observation(pitchEgocentric: 40),  // t=10: big delta -> baseline drifts fully to 40
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)
    _ = try await engine.process(capturedFrame(atSeconds: 0))
    _ = try await engine.process(capturedFrame(atSeconds: 10))

    let drifted = await engine.learnedGazeBaseline()
    #expect(
      drifted.pitchDegrees == 40,
      "sanity: the baseline actually moved before the updateConfig under test")

    var tweaked = config
    tweaked.smoothingWindow = 5  // unrelated slider; neutralPitchDegrees stays 30
    await engine.updateConfig(tweaked)

    let afterTweak = await engine.learnedGazeBaseline()
    #expect(
      afterTweak.pitchDegrees == 40,
      "must NOT snap back to the unchanged captured neutral (30)")
  }

  // MARK: - baselineLearningEnabled = false (static compat)

  @Test("baselineLearningEnabled = false never seeds or adapts, even from in-zone frames")
  func learningDisabledNeverAdapts() async throws {
    var config = Config.defaults
    config.gaze.baselineLearningEnabled = false
    let script: [RawFaceObservation?] = Array(
      repeating: observation(pitchEgocentric: 40), count: 5)
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    for index in 0..<5 {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      // Static comparison vs. neutralPitchDegrees (0, never captured): |40-0| = 40 > 15.
      #expect(output.framing?.gazeOnCamera == false, "frame \(index)")
    }

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.yawDegrees == nil)
    #expect(baseline.pitchDegrees == nil)
  }

  // MARK: - Eligibility gates

  @Test("Out-of-zone frames never seed or adapt the baseline")
  func outOfZoneFramesNeverAdapt() async throws {
    let script: [RawFaceObservation?] = Array(
      repeating: observation(pitchEgocentric: 30, inZone: false), count: 5)
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    for index in 0..<5 {
      _ = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
    }
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.pitchDegrees == nil)
  }

  @Test("Low-confidence frames never seed or adapt the baseline")
  func lowConfidenceFramesNeverAdapt() async throws {
    let script: [RawFaceObservation?] = Array(
      repeating: observation(pitchEgocentric: 30, confidence: 0.3), count: 5)
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    for index in 0..<5 {
      _ = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
    }
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.pitchDegrees == nil)
  }

  @Test("No-face frames never seed the baseline")
  func noFaceFramesNeverSeed() async throws {
    let script: [RawFaceObservation?] = [nil, nil, nil]
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    for index in 0..<3 {
      _ = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
    }
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.pitchDegrees == nil)
  }

  // MARK: - Reset semantics (face loss)

  @Test("Face loss does not reset an already-learned baseline")
  func faceLossDoesNotResetBaseline() async throws {
    var config = Config.defaults
    config.targetFraming.neutralPitchDegrees = 30  // capture-seeded at construction
    config.gaze.baselineAdaptationSeconds = 1

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(pitchEgocentric: 30),  // t=0: establishes a cadence reference
      nil,  // t=1: face lost
      nil,  // t=2: still lost
      observation(pitchEgocentric: 30),  // t=3: reacquired, same pose
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    for index in 0..<4 {
      _ = try await engine.process(capturedFrame(atSeconds: Double(index)))
    }

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.pitchDegrees == 30, "the captured value survives the face-loss gap untouched")
  }
}
