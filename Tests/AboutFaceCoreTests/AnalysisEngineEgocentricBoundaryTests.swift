import CoreGraphics
import Testing

@testable import AboutFaceCore

/// The spec's §3.4 MUST-have test, replayed through the full
/// `AnalysisEngine.process(_:)` pipeline (not just `EgocentricTransform`
/// directly, which `EgocentricTransformTests` already covers): "a corpus
/// clip where the subject is unambiguously to their own left produces
/// `error.x < 0`... under both mirrored and unmirrored capture
/// configuration."
///
/// ## Deriving the raw observation per mirror config
///
/// Same physical scene both times: the subject standing to their own left.
/// Per `EgocentricTransform`'s doc comment (and `EgocentricTransformTests`,
/// which hand-derives these exact numbers):
///
/// - Unmirrored (raw sensor image, subject appears on frame's right, as
///   when facing another person): raw image X ≈ 0.8 → egocentric X = 1 -
///   0.8 = 0.2.
/// - Mirrored (subject appears on frame's left, as in a real mirror): raw
///   image X ≈ 0.2 → egocentric X = 0.2 (identity).
///
/// Both must agree on egocentric X = 0.2, which is left of the default
/// centered target (0.5), giving `error.x = 0.2 - 0.5 = -0.3 < 0`.
///
/// ## Deriving the yaw sign per mirror config
///
/// Same physical head turn both times: the subject turned toward their own
/// right. Per `AnalysisEngine.egocentricPose(raw:mirror:)`'s doc comment
/// (established by controlled live movement, 2026-08-01): Vision raw yaw
/// positive = own LEFT, so a physical turn toward the subject's own right
/// reports raw yaw = -20° on `.notMirrored` frames, which the boundary
/// negates to egocentric +20°. For `.mirrored`, Vision ran on
/// already-flipped pixels for the SAME physical turn — the flip negates
/// yaw, so raw = +20°, passed through unchanged. Both configs must agree
/// on egocentric yaw = +20°.
struct AnalysisEngineEgocentricBoundaryTests {

  private static let tolerance: Float = 1e-4

  private func rawObservation(
    rawCenterX: CGFloat, rawYaw: Float, rawPitch: Float = 0
  ) -> RawFaceObservation {
    let halfWidth: CGFloat = 0.1
    let boundingBox = CGRect(
      x: rawCenterX - halfWidth, y: 0.4, width: halfWidth * 2, height: 0.3)
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let eyePoints = [
      CGPoint(x: rawCenterX - 0.02, y: 0.55),
      CGPoint(x: rawCenterX + 0.02, y: 0.55),
    ]
    // swiftlint:enable trailing_comma
    return RawFaceObservation(
      boundingBox: boundingBox,
      eyePoints: eyePoints,
      yaw: rawYaw,
      pitch: rawPitch,
      roll: 0,
      confidence: 0.9,
      faceCount: 1
    )
  }

  @Test("Subject to own left, unmirrored: error.x < 0 and egocentric yaw passes through")
  func ownLeft_notMirrored() async throws {
    let raw = rawObservation(rawCenterX: 0.8, rawYaw: -20)
    let backend = ScriptedBackend([raw])
    let engine = AnalysisEngine(backend: backend)

    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))

    let errorX = try #require(output.framing?.error.x)
    #expect(errorX < 0)
    let yaw = try #require(output.analysis.primary?.yaw)
    #expect(abs(yaw - 20) < Self.tolerance)
  }

  @Test("Subject to own left, mirrored: error.x < 0 and yaw is negated back to egocentric")
  func ownLeft_mirrored() async throws {
    let raw = rawObservation(rawCenterX: 0.2, rawYaw: 20)
    let backend = ScriptedBackend([raw])
    let engine = AnalysisEngine(backend: backend)

    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .mirrored))

    let errorX = try #require(output.framing?.error.x)
    #expect(errorX < 0)
    let yaw = try #require(output.analysis.primary?.yaw)
    #expect(abs(yaw - 20) < Self.tolerance)
  }

  @Test(
    "Pitch is negated in BOTH mirror states: Vision raw + (chin down) becomes §3.3 − (chin down)")
  func pitchNegatedBothMirrorStates() async throws {
    // Vision raw pitch positive = chin DOWN (corrected 2026-08-01 by a
    // controlled live head-movement test; see ATTRIBUTION.md). §3.3 wants
    // + = chin up, so a raw +10° (subject chin-down) must surface as −10°
    // regardless of mirror state — a horizontal flip does not affect pitch,
    // so unlike yaw/roll the negation is mirror-independent.
    for mirror in [MirrorState.notMirrored, .mirrored] {
      let rawX: CGFloat = mirror == .notMirrored ? 0.8 : 0.2
      let rawYaw: Float = mirror == .notMirrored ? -20 : 20
      let engine = AnalysisEngine(
        backend: ScriptedBackend([rawObservation(rawCenterX: rawX, rawYaw: rawYaw, rawPitch: 10)]))
      let output = try await engine.process(
        testFrame(pixelBuffer: gradientPixelBuffer(), mirror: mirror))
      let pitch = try #require(output.analysis.primary?.pitch)
      #expect(abs(pitch - (-10)) < Self.tolerance, "mirror=\(mirror): expected −10, got \(pitch)")
    }
  }

  @Test("Both mirror configs agree on error.x and yaw for the same physical scene")
  func agreesAcrossMirrorStates() async throws {
    let notMirroredEngine = AnalysisEngine(
      backend: ScriptedBackend([rawObservation(rawCenterX: 0.8, rawYaw: -20)]))
    let mirroredEngine = AnalysisEngine(
      backend: ScriptedBackend([rawObservation(rawCenterX: 0.2, rawYaw: 20)]))

    let notMirroredOutput = try await notMirroredEngine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    let mirroredOutput = try await mirroredEngine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .mirrored))

    let notMirroredErrorX = try #require(notMirroredOutput.framing?.error.x)
    let mirroredErrorX = try #require(mirroredOutput.framing?.error.x)
    #expect(abs(notMirroredErrorX - mirroredErrorX) < Self.tolerance)

    let notMirroredYaw = try #require(notMirroredOutput.analysis.primary?.yaw)
    let mirroredYaw = try #require(mirroredOutput.analysis.primary?.yaw)
    #expect(abs(notMirroredYaw - mirroredYaw) < Self.tolerance)
  }
}
