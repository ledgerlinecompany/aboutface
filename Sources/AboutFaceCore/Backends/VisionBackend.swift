/// The v1 `FaceAnalysisBackend` conformance, backed by macOS 15's Swift-native
/// Vision API (`DetectFaceRectanglesRequest`, `DetectFaceCaptureQualityRequest`,
/// `DetectFaceLandmarksRequest` — see spec §3.2).
///
/// This is Phase 1 **scaffolding only**. No Vision request is issued yet;
/// `analyze(_:)` always returns `nil`. Wiring up real inference is the next
/// task after this package skeleton is in place, not part of scaffolding.
public struct VisionBackend: FaceAnalysisBackend {
  public static let identifier = "vision"
  public static let displayName = "Apple Vision"
  public static let isAvailable = true

  public let capabilities: BackendCapabilities = [.captureQuality, .multiFace, .headPose]

  public init() {}

  public func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation? {
    // TODO(Phase 1): issue DetectFaceRectanglesRequest, DetectFaceCaptureQualityRequest,
    // and DetectFaceLandmarksRequest against frame.pixelBuffer and map the results into
    // a backend-native RawFaceObservation. Real inference lands with the AnalysisEngine
    // work; this conformance is scaffolding only so the package compiles and the
    // protocol shape can be exercised by tests.
    return nil
  }
}
