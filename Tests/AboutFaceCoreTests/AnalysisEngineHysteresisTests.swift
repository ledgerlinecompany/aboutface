import CoreGraphics
import Testing

@testable import AboutFaceCore

struct AnalysisEngineHysteresisTests {

  @Test("Oscillating error around the dead-zone entry threshold does not chatter")
  func oscillationDoesNotChatter() async throws {
    // window = 1 -> alpha = 2/(1+1) = 1 -> smoothed == raw exactly, every
    // frame. This isolates hysteresis behavior from EMA lag so the
    // expected inDeadZone sequence below can be reasoned about purely from
    // the raw error values and the documented entry/exit thresholds.
    var config = Config.defaults
    config.smoothingWindow = 1
    // Defaults: deadZone.horizontal = 0.06, hysteresisExitRatio = 1.4 ->
    // exit threshold = 0.084. deadZone.vertical is generous (0.05) and Y is
    // held at the target throughout, so only X drives the latch here.

    let targetYBottomLeftOrigin = CGFloat(1 - Config.defaults.targetFraming.eyeMidpointY)

    func observation(errorX: Float) -> RawFaceObservation {
      // notMirrored: egocentricX = 1 - rawImageX, target = 0.5, so
      // rawImageX = 1 - (0.5 + errorX) = 0.5 - errorX.
      let rawX = CGFloat(0.5 - errorX)
      // swiftlint and swift-format disagree on trailing commas in multiline collection
      // literals (swift-format requires them, swiftlint's default forbids them); this
      // block satisfies `swift format lint`, which the CI gate also enforces.
      // swiftlint:disable trailing_comma
      let eyePoints = [
        CGPoint(x: rawX - 0.02, y: targetYBottomLeftOrigin),
        CGPoint(x: rawX + 0.02, y: targetYBottomLeftOrigin),
      ]
      // swiftlint:enable trailing_comma
      return RawFaceObservation(
        boundingBox: CGRect(x: rawX - 0.1, y: 0.4, width: 0.2, height: 0.3),
        eyePoints: eyePoints,
        yaw: 0, pitch: 0, roll: 0,
        confidence: 0.9, faceCount: 1
      )
    }

    // 0.2: well outside entry (0.06) -> false.
    // 0.05: inside entry -> latches true.
    // 0.07, 0.05, 0.07, 0.05: oscillate between entry (0.06) and exit
    //   (0.084) -> latch must stay true throughout (no chatter).
    // 0.09: exceeds exit (0.084) -> latches false.
    // 0.05: inside entry again -> re-latches true.
    let errorSequence: [Float] = [0.2, 0.05, 0.07, 0.05, 0.07, 0.05, 0.09, 0.05]
    let expectedInDeadZone = [false, true, true, true, true, true, false, true]

    let script = errorSequence.map { observation(errorX: $0) as RawFaceObservation? }
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    var actual: [Bool] = []
    for index in errorSequence.indices {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      actual.append(try #require(output.framing).inDeadZone)
    }

    #expect(actual == expectedInDeadZone)
  }
}
