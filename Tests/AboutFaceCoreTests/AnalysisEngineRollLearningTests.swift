import CoreGraphics
import CoreMedia
import Testing

@testable import AboutFaceCore

/// §4 extension, maintainer 2026-08-02: "Agreed, it's part of gaze" — roll
/// joins the exact same capture-free learned-baseline machinery
/// (`AnalysisEngine+GazeBaseline.swift`) that
/// `AnalysisEngineGazeLearningTests` covers for yaw/pitch: same seed/adapt/
/// clamp/eligibility/reset semantics, same `Config.Gaze.baselineLearningEnabled`
/// compatibility escape hatch, same `Config.Gaze.baselineAdaptationSeconds`/
/// `baselineClampDegrees` knobs (shared across all three axes, not
/// per-roll). This file mirrors that one's structure and fixture idioms,
/// scoped to roll/`FramingState.headLevel`, plus the regression that
/// motivated keeping roll OUT of `inDeadZone` in the first place: a tilted
/// arrival must still enter the good zone and still chime.
struct AnalysisEngineRollLearningTests {

  // MARK: - Fixture builders

  /// A `RawFaceObservation` at a given egocentric roll, positioned either
  /// inside or outside `Config.defaults`' positional dead zone. Mirrors
  /// `AnalysisEngineGazeLearningTests.observation(pitchEgocentric:...)`;
  /// unlike yaw/pitch, `.notMirrored` roll passes through unnegated
  /// (`egocentricPose(raw:mirror:)`: `roll: rawRoll`), so the raw value
  /// handed to `RawFaceObservation` IS the desired egocentric roll directly.
  private func observation(
    rollEgocentric: Float,
    confidence: Float = 0.9,
    inZone: Bool = true
  ) -> RawFaceObservation {
    let (leftX, rightX): (CGFloat, CGFloat) = inZone ? (0.445, 0.555) : (0.0, 0.11)
    return RawFaceObservation(
      boundingBox: CGRect(x: 0.4, y: 0.47, width: 0.2, height: 0.3),
      eyePoints: [CGPoint(x: leftX, y: 0.62), CGPoint(x: rightX, y: 0.62)],
      yaw: 0,
      pitch: 0,
      roll: rollEgocentric,
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

  // MARK: - Zero-capture path: seed/adapt (the yaw/pitch regression's cousin)

  @Test("Zero-capture defaults: headLevel reads meaningfully once the baseline seeds from behavior")
  func zeroCaptureSeedsFromBehaviorAndTracksIt() async throws {
    // Config.defaults: no capture (neutralRollDegrees == 0), learning
    // enabled. A stable tilt +20 (the user's natural resting tilt) held
    // across several in-zone frames.
    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 20),
      observation(rollEgocentric: 20),
      observation(rollEgocentric: 20),
      observation(rollEgocentric: 20),
      // A sharp, sustained deviation — a genuine held tilt away from
      // neutral, the analog of §14 clip 11's gaze finding.
      observation(rollEgocentric: -30),
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    // Frame 0: unseeded yet (fallback to the static neutral, 0), so this
    // exact frame reads NOT level (|20 - 0| = 20 > maxRollDegrees 10) — not
    // asserted, just documented: the seed happens ON this frame.
    _ = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 0))

    // Frames 1-3: baseline is seeded at 20 and the tilt hasn't moved, so it
    // reads level with zero calibration ever having happened.
    for index in 1...3 {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      #expect(output.framing?.headLevel == true, "frame \(index)")
    }

    // Frame 4: judged against the baseline AS IT STOOD BEFORE this frame
    // (adaptation lags comparison by one frame) — a sharp deviation is
    // caught immediately, not gradually accepted.
    let deviated = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 4))
    #expect(deviated.framing?.headLevel == false)

    // The whole point of keeping roll out of `inDeadZone` (§4 extension):
    // a held tilt while otherwise perfectly placed never gates settle.
    #expect(deviated.framing?.inDeadZone == true, "tilt must never gate the dead zone")
  }

  // MARK: - Adaptation speed (hand-derived EMA)

  @Test("Roll baseline follows a sustained tilt shift at the configured time constant")
  func adaptationFollowsTimeConstant() async throws {
    var config = Config.defaults
    config.gaze.baselineAdaptationSeconds = 4  // tau = 4s

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 30),  // t=0: seeds at 30
      observation(rollEgocentric: 36),  // t=1: step to 36, held
      observation(rollEgocentric: 36),  // t=2
      observation(rollEgocentric: 36),  // t=3
      observation(rollEgocentric: 36),  // t=4
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    // Identical arithmetic to AnalysisEngineGazeLearningTests's pitch
    // derivation (same tau, same step) — the EMA formula is axis-agnostic.
    // alpha = deltaSeconds / tau = 1/4 = 0.25 at every 1s step.
    let expected: [Float] = [30, 31.5, 32.625, 33.46875, 34.1015625]
    let tolerance: Float = 1e-4

    for (index, expectedRoll) in expected.enumerated() {
      _ = try await engine.process(capturedFrame(atSeconds: Double(index)))
      let baseline = await engine.learnedGazeBaseline()
      let roll = try #require(baseline.rollDegrees)
      #expect(
        abs(roll - expectedRoll) < tolerance,
        "frame \(index): expected \(expectedRoll), got \(roll)")
    }
  }

  // MARK: - Clamp

  @Test("Learned roll baseline cannot wander past baselineClampDegrees from its seed")
  func baselineClampsAtConfiguredDistanceFromSeed() async throws {
    var config = Config.defaults
    config.gaze.baselineAdaptationSeconds = 1  // tau = 1s
    config.gaze.baselineClampDegrees = 25
    // Default maxRollDegrees (10) already leaves an unambiguous gap below
    // the clamped-vs-actual deviation this test produces (15) — unlike
    // AnalysisEngineGazeLearningTests's pitch clamp test, no threshold
    // override is needed here to avoid a `<=` boundary ambiguity.

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 30),  // t=0: seeds at 30
      observation(rollEgocentric: 70),  // t=10: seed+40, big delta -> alpha saturates at 1
      observation(rollEgocentric: 70),  // t=20: held; baseline already clamped
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    _ = try await engine.process(capturedFrame(atSeconds: 0))
    _ = try await engine.process(capturedFrame(atSeconds: 10))
    let afterFirstJump = await engine.learnedGazeBaseline()
    // blended = 1*70 + 0*30 = 70, clamped to seed(30) + 25 = 55.
    #expect(afterFirstJump.rollDegrees == 55)

    let holding = try await engine.process(capturedFrame(atSeconds: 20))
    // headLevel for THIS frame reads the baseline from the previous frame
    // (55, not a fresh unclamped 70): |70 - 55| = 15 > maxRollDegrees(10).
    #expect(holding.framing?.headLevel == false)
    // Still never gates the dead zone.
    #expect(holding.framing?.inDeadZone == true)

    let stillClamped = await engine.learnedGazeBaseline()
    #expect(stillClamped.rollDegrees == 55, "stops at seed+25, does not keep climbing toward 70")
  }

  // MARK: - Capture precedence

  @Test("Nonzero captured neutralRollDegrees seeds the baseline exactly, at construction")
  func captureSeedsBaselineExactlyOnInit() async throws {
    var config = Config.defaults
    config.targetFraming.neutralRollDegrees = 15
    let engine = AnalysisEngine(backend: ScriptedBackend([]), config: config)

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == 15)
    // Yaw/pitch stay unseeded — captureSeed only fires all three together
    // when at least one is nonzero, but a roll-only capture still seeds
    // yaw/pitch at their own (zero) neutral, per `captureSeed`'s doc
    // comment ("captured the WHOLE pose at once").
    #expect(baseline.yawDegrees == 0)
    #expect(baseline.pitchDegrees == 0)
  }

  @Test("updateConfig with changed nonzero captured neutralRollDegrees re-seeds the baseline")
  func updateConfigWithChangedCaptureReseeds() async throws {
    var config = Config.defaults
    config.targetFraming.neutralRollDegrees = 15
    let engine = AnalysisEngine(backend: ScriptedBackend([]), config: config)

    var recaptured = config
    recaptured.targetFraming.neutralRollDegrees = -8
    await engine.updateConfig(recaptured)

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == -8)
  }

  @Test("updateConfig with UNCHANGED captured neutralRollDegrees does not reseed")
  func updateConfigWithUnchangedCaptureDoesNotReseed() async throws {
    var config = Config.defaults
    config.targetFraming.neutralRollDegrees = 30  // captured
    config.gaze.baselineAdaptationSeconds = 1

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 30),  // t=0: cadence reference; baseline stays 30
      observation(rollEgocentric: 40),  // t=10: big delta -> baseline drifts fully to 40
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)
    _ = try await engine.process(capturedFrame(atSeconds: 0))
    _ = try await engine.process(capturedFrame(atSeconds: 10))

    let drifted = await engine.learnedGazeBaseline()
    #expect(
      drifted.rollDegrees == 40,
      "sanity: the baseline actually moved before the updateConfig under test")

    var tweaked = config
    tweaked.smoothingWindow = 5  // unrelated slider; neutralRollDegrees stays 30
    await engine.updateConfig(tweaked)

    let afterTweak = await engine.learnedGazeBaseline()
    #expect(
      afterTweak.rollDegrees == 40, "must NOT snap back to the unchanged captured neutral (30)")
  }

  // MARK: - baselineLearningEnabled = false (static compat) — both sides of maxRollDegrees

  @Test(
    "baselineLearningEnabled = false: headLevel is a static comparison, both sides of the threshold"
  )
  func learningDisabledIsStaticBothSides() async throws {
    var config = Config.defaults
    config.gaze.baselineLearningEnabled = false
    config.targetFraming.neutralRollDegrees = 20
    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 27),  // |27-20| = 7 <= 10: level
      observation(rollEgocentric: 33),  // |33-20| = 13 > 10: not level
      observation(rollEgocentric: 8),  // |8-20| = 12 > 10: not level (other side)
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    let near = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 0))
    #expect(near.framing?.headLevel == true)

    let farAbove = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 1))
    #expect(farAbove.framing?.headLevel == false)

    let farBelow = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: 2))
    #expect(farBelow.framing?.headLevel == false)

    // The capture itself still seeds `learnedGazeBaseline()` (seeding is
    // unconditional in `init`/`updateConfig` — only `adaptLearnedBaseline`
    // and `effectiveBaselineRoll` respect the disabled flag), but
    // `headLevel` above never reads it: with `baselineLearningEnabled ==
    // false`, `effectiveBaselineRoll` returns `target.neutralRollDegrees`
    // unconditionally, and none of the three frames above ever adapted it
    // (still exactly the seed value, never drifted toward 27/33/8).
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == 20)
  }

  // MARK: - Eligibility gates (shared with yaw/pitch — same `eligible` flag)

  @Test("Out-of-zone frames never seed or adapt the roll baseline")
  func outOfZoneFramesNeverAdaptRoll() async throws {
    let script: [RawFaceObservation?] = Array(
      repeating: observation(rollEgocentric: 30, inZone: false), count: 5)
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    for index in 0..<5 {
      _ = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
    }
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == nil)
  }

  @Test("Low-confidence frames never seed or adapt the roll baseline")
  func lowConfidenceFramesNeverAdaptRoll() async throws {
    let script: [RawFaceObservation?] = Array(
      repeating: observation(rollEgocentric: 30, confidence: 0.3), count: 5)
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: .defaults)

    for index in 0..<5 {
      _ = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
    }
    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == nil)
  }

  // MARK: - Reset semantics (face loss)

  @Test("Face loss does not reset an already-learned roll baseline")
  func faceLossDoesNotResetRollBaseline() async throws {
    var config = Config.defaults
    config.targetFraming.neutralRollDegrees = 30  // capture-seeded at construction
    config.gaze.baselineAdaptationSeconds = 1

    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rollEgocentric: 30),  // t=0: establishes a cadence reference
      nil,  // t=1: face lost
      nil,  // t=2: still lost
      observation(rollEgocentric: 30),  // t=3: reacquired, same tilt
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    for index in 0..<4 {
      _ = try await engine.process(capturedFrame(atSeconds: Double(index)))
    }

    let baseline = await engine.learnedGazeBaseline()
    #expect(baseline.rollDegrees == 30, "the captured value survives the face-loss gap untouched")
  }
}
