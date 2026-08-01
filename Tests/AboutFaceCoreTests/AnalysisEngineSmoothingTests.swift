import CoreGraphics
import Testing

@testable import AboutFaceCore

/// Hand-computed exponential moving average, per
/// `AnalysisEngine+Framing.swift`'s documented `ema` formula
/// `alpha = 2 / (window + 1)`, seeded with the first raw sample.
struct AnalysisEngineSmoothingTests {

  @Test("Step input: smoothed error.x follows the exact hand-computed EMA curve")
  func stepInput_exactEmaValues() async throws {
    // window = 3 -> alpha = 2 / (3 + 1) = 0.5, chosen for clean arithmetic.
    var config = Config.defaults
    config.smoothingWindow = 3

    // Frame 1: subject centered (raw error.x = 0). First sample seeds
    // smoothed = raw exactly (the engine's documented EMA seeding
    // behavior), so this frame is priming, not part of the step response.
    //
    // Frames 2-5: subject jumps to and holds egocentric x = 0.9 (raw
    // error.x = 0.9 - 0.5 = 0.4) -> a step input from smoothed = 0.
    //
    // notMirrored: egocentricX = 1 - rawImageX, so rawImageX = 1 - egocentricX.
    let centeredRawX: CGFloat = 1 - 0.5  // egocentric 0.5
    let steppedRawX: CGFloat = 1 - 0.9  // egocentric 0.9

    func observation(rawX: CGFloat) -> RawFaceObservation {
      RawFaceObservation(
        boundingBox: CGRect(x: rawX - 0.1, y: 0.4, width: 0.2, height: 0.3),
        eyePoints: [CGPoint(x: rawX - 0.02, y: 0.55), CGPoint(x: rawX + 0.02, y: 0.55)],
        yaw: 0, pitch: 0, roll: 0,
        confidence: 0.9, faceCount: 1
      )
    }

    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let script: [RawFaceObservation?] = [
      observation(rawX: centeredRawX),
      observation(rawX: steppedRawX),
      observation(rawX: steppedRawX),
      observation(rawX: steppedRawX),
      observation(rawX: steppedRawX),
    ]
    // swiftlint:enable trailing_comma
    let engine = AnalysisEngine(backend: ScriptedBackend(script), config: config)

    // alpha = 0.5, raw = 0.4 from frame 2 onward, smoothed_1 = 0 (seed).
    // smoothed_2 = 0.5*0.4 + 0.5*0   = 0.2
    // smoothed_3 = 0.5*0.4 + 0.5*0.2 = 0.3
    // smoothed_4 = 0.5*0.4 + 0.5*0.3 = 0.35
    // smoothed_5 = 0.5*0.4 + 0.5*0.35 = 0.375
    let expected: [Float] = [0, 0.2, 0.3, 0.35, 0.375]
    let tolerance: Float = 1e-4

    for (index, expectedValue) in expected.enumerated() {
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored, frameIndex: index))
      let errorX = try #require(output.framing?.error.x)
      #expect(
        abs(errorX - expectedValue) < tolerance,
        "frame \(index): expected \(expectedValue), got \(errorX)"
      )
    }
  }
}
