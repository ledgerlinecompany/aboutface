import CoreGraphics
import Testing

@testable import AboutFaceCore

/// The §4 extension from Phase 2 field testing: `gazeOnCamera` measures
/// deviation from the captured neutral-pose baseline
/// (`Config.TargetFraming.neutral*Degrees`), not absolute camera-ray
/// angles — a laptop camera views the face from off the natural eyeline,
/// so a natural head position read ~+30° chin-up in the field.
struct AnalysisEngineGazeBaselineTests {

  private func engine(
    neutralPitch: Double, observing pitchEgocentric: Float, maxPitch: Double = 15
  ) -> AnalysisEngine {
    var config = Config.defaults
    config.targetFraming.neutralPitchDegrees = neutralPitch
    config.gaze.maxPitchDegrees = maxPitch
    let backend = ScriptedBackend([observation(pitchEgocentric: pitchEgocentric)])
    return AnalysisEngine(backend: backend, config: config)
  }

  private func observation(pitchEgocentric: Float) -> RawFaceObservation {
    // Vision raw pitch positive = chin down; the boundary negates, so a
    // desired egocentric pitch of +P needs raw pitch of -P.
    RawFaceObservation(
      boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
      eyePoints: [CGPoint(x: 0.48, y: 0.55), CGPoint(x: 0.52, y: 0.55)],
      yaw: 0,
      pitch: -pitchEgocentric,
      roll: 0,
      confidence: 0.9,
      faceCount: 1
    )
  }

  @Test("Pose near the captured neutral counts as gaze-on-camera")
  func nearNeutral_isOnCamera() async throws {
    let engine = engine(neutralPitch: 30, observing: 32)
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    #expect(output.framing?.gazeOnCamera == true)
  }

  @Test("Pose far from the captured neutral is not gaze-on-camera, even if absolutely small")
  func farFromNeutral_isOffCamera() async throws {
    // Absolute pitch 5° would pass an absolute-threshold check, but the
    // user's neutral is 30° — a 25° deviation means they moved their head
    // substantially (e.g. looking down at a second monitor, §14 clip 11).
    let engine = engine(neutralPitch: 30, observing: 5)
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    #expect(output.framing?.gazeOnCamera == false)
  }

  @Test("Zero baseline (never captured) degrades to the absolute behavior")
  func zeroBaseline_absoluteBehavior() async throws {
    let engine = engine(neutralPitch: 0, observing: 10)
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    #expect(output.framing?.gazeOnCamera == true)
  }
}
