import CoreGraphics
import Testing

@testable import AboutFaceCore

struct AnalysisEngineHysteresisTests {

  /// Shared across every test below: builds a `RawFaceObservation` with eye
  /// points separated by `interocularWidth` in raw-image space (default
  /// `Config.defaults.targetFraming.interocularWidth`, 0.11) — since
  /// `AnalysisEngine+Geometry.swift`'s `interocularDistance` is
  /// mirror-invariant `abs(right.x - left.x)`, this holds `distanceError`
  /// at (or offset from) 0 independent of `errorX`, so each test can drive
  /// exactly the axis/axes it's exercising and leave the others pinned at
  /// target.
  private static func observation(
    errorX: Float, interocularWidth: Double = Config.defaults.targetFraming.interocularWidth
  ) -> RawFaceObservation {
    let targetYBottomLeftOrigin = CGFloat(1 - Config.defaults.targetFraming.eyeMidpointY)
    // notMirrored: egocentricX = 1 - rawImageX, target = 0.5, so
    // rawImageX = 1 - (0.5 + errorX) = 0.5 - errorX.
    let rawX = CGFloat(0.5 - errorX)
    let halfWidth = CGFloat(interocularWidth) / 2
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let eyePoints = [
      CGPoint(x: rawX - halfWidth, y: targetYBottomLeftOrigin),
      CGPoint(x: rawX + halfWidth, y: targetYBottomLeftOrigin),
    ]
    // swiftlint:enable trailing_comma
    return RawFaceObservation(
      boundingBox: CGRect(x: rawX - 0.1, y: 0.4, width: 0.2, height: 0.3),
      eyePoints: eyePoints,
      yaw: 0, pitch: 0, roll: 0,
      confidence: 0.9, faceCount: 1
    )
  }

  /// Runs `errorSequence` (converted to `RawFaceObservation`s via
  /// `observation(errorX:interocularWidth:)`) through a fresh engine, one
  /// frame per instant, and returns the `inDeadZone` observed each frame.
  private func runInDeadZoneSequence(
    errorSequence: [(errorX: Float, interocularWidth: Double)], config: Config
  ) async throws -> [Bool] {
    let script = errorSequence.map {
      Self.observation(errorX: $0.errorX, interocularWidth: $0.interocularWidth)
        as RawFaceObservation?
    }
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    var actual: [Bool] = []
    for index in errorSequence.indices {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      actual.append(try #require(output.framing).inDeadZone)
    }
    return actual
  }

  @Test("Oscillating error around the dead-zone entry threshold does not chatter")
  func oscillationDoesNotChatter() async throws {
    // window = 1 -> alpha = 2/(1+1) = 1 -> smoothed == raw exactly, every
    // frame. This isolates hysteresis behavior from EMA lag so the
    // expected inDeadZone sequence below can be reasoned about purely from
    // the raw error values and the documented entry/exit thresholds.
    var config = Config.defaults
    config.smoothingWindow = 1
    // Defaults: deadZone.horizontal = 0.06, hysteresisExitRatio = 1.4 ->
    // exit threshold = 0.084. deadZone.vertical (0.05) and deadZone.distance
    // (0.02) are both held at target throughout (Y via `observation`'s fixed
    // `targetYBottomLeftOrigin`; distance via the default `interocularWidth`
    // argument, which pins `distanceError == 0`), so only X drives the latch
    // here.

    // 0.2: well outside entry (0.06) -> false.
    // 0.05: inside entry -> latches true.
    // 0.07, 0.05, 0.07, 0.05: oscillate between entry (0.06) and exit
    //   (0.084) -> latch must stay true throughout (no chatter).
    // 0.09: exceeds exit (0.084) -> latches false.
    // 0.05: inside entry again -> re-latches true.
    let errorXSequence: [Float] = [0.2, 0.05, 0.07, 0.05, 0.07, 0.05, 0.09, 0.05]
    let expectedInDeadZone = [false, true, true, true, true, true, false, true]

    let errorSequence = errorXSequence.map {
      (errorX: $0, interocularWidth: config.targetFraming.interocularWidth)
    }
    let actual = try await runInDeadZoneSequence(errorSequence: errorSequence, config: config)

    #expect(actual == expectedInDeadZone)
  }

  // MARK: - Distance joins the dead zone (§4 extension, 2026-08-02 finding)

  /// **Real-world scenario this reproduces:** the maintainer's first live
  /// convergence trial settled "converged" purely by ear because centering
  /// laterally silenced the tone — the only distance cue there is (§6.2
  /// tremolo on the positional tone) — even with distance still far off
  /// target. With distance now part of the latch, X within entry threshold
  /// alone is no longer sufficient: the tone (and its distance indicator)
  /// must keep playing (`inDeadZone == false`) until distance is ALSO
  /// within threshold.
  @Test("Distance-only error keeps the latch OUT of the dead zone even with x/y centered")
  func distanceOnlyErrorStaysOutOfDeadZone() async throws {
    var config = Config.defaults
    config.smoothingWindow = 1
    // deadZone.distance default 0.02; target interocularWidth default 0.11.
    // interocularWidth = 0.2 -> distanceError = 0.2 - 0.11 = 0.09, well
    // outside the 0.02 entry threshold, while errorX == 0 (dead center).
    let sequence: [(errorX: Float, interocularWidth: Double)] = [(0, 0.2), (0, 0.2), (0, 0.2)]
    let actual = try await runInDeadZoneSequence(errorSequence: sequence, config: config)
    #expect(actual == [false, false, false])
  }

  /// Entering the dead zone requires ALL THREE axes within their entry
  /// thresholds simultaneously — x/y alone, however well centered, must not
  /// latch until distance also settles.
  @Test("Entering the dead zone requires x, y, AND distance all within entry thresholds")
  func enteringRequiresAllThreeAxes() async throws {
    var config = Config.defaults
    config.smoothingWindow = 1
    let target = config.targetFraming.interocularWidth

    // Frame 1: x centered, distance far off (0.09 error) -> still out.
    // Frame 2: x centered, distance now within entry (0.01 error) -> latches
    // in, since y is held at target throughout by `observation`'s fixed Y.
    // swiftlint:disable trailing_comma
    let sequence: [(errorX: Float, interocularWidth: Double)] = [
      (0, target + 0.09),
      (0, target + 0.01),
    ]
    // swiftlint:enable trailing_comma
    let actual = try await runInDeadZoneSequence(errorSequence: sequence, config: config)
    #expect(actual == [false, true])
  }

  /// Mirrors `oscillationDoesNotChatter` but drives distance instead of x:
  /// oscillating between the distance entry (0.02) and exit (0.028)
  /// thresholds must not chatter the latch.
  @Test("Oscillating distance error around its entry threshold does not chatter")
  func distanceOscillationDoesNotChatter() async throws {
    var config = Config.defaults
    config.smoothingWindow = 1
    let target = config.targetFraming.interocularWidth
    // deadZone.distance = 0.02, hysteresisExitRatio = 1.4 -> exit = 0.028.

    // 0.2: well outside entry -> false.
    // 0.01: inside entry -> latches true.
    // 0.025, 0.01, 0.025, 0.01: oscillate between entry (0.02) and exit
    //   (0.028) -> latch must stay true throughout.
    // 0.03: exceeds exit (0.028) -> latches false.
    // 0.01: inside entry again -> re-latches true.
    let distanceErrorSequence: [Double] = [0.2, 0.01, 0.025, 0.01, 0.025, 0.01, 0.03, 0.01]
    let expectedInDeadZone = [false, true, true, true, true, true, false, true]

    let sequence = distanceErrorSequence.map {
      (errorX: Float(0), interocularWidth: target + $0)
    }
    let actual = try await runInDeadZoneSequence(errorSequence: sequence, config: config)
    #expect(actual == expectedInDeadZone)
  }

  /// Once latched in, exiting requires only ONE axis to exceed its exit
  /// threshold — here x and y both stay comfortably within entry the whole
  /// time; distance alone crossing its exit threshold is sufficient to drop
  /// the latch, matching the "exit when ANY axis exceeds" half of the
  /// extended rule.
  @Test("Distance alone exceeding its exit threshold drops an already-latched dead zone")
  func distanceAloneExitsAnAlreadyLatchedDeadZone() async throws {
    var config = Config.defaults
    config.smoothingWindow = 1
    let target = config.targetFraming.interocularWidth

    // swiftlint:disable trailing_comma
    let sequence: [(errorX: Float, interocularWidth: Double)] = [
      (0, target),  // latches in: x, y, distance all at target.
      (0, target + 0.03),  // distance error 0.03 > exit 0.028 -> drops out.
    ]
    // swiftlint:enable trailing_comma
    let actual = try await runInDeadZoneSequence(errorSequence: sequence, config: config)
    #expect(actual == [true, false])
  }
}
