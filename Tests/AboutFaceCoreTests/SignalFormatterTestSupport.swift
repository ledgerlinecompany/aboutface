import CoreGraphics
import CoreMedia

@testable import AboutFaceCore

// MARK: - Shared fixture builders for SignalFormatter*Tests
//
// Free functions (not instance methods) so both `SignalFormatterTests` and
// `SignalFormatterSnapshotTests` can use them — matching
// `AnalysisEngineTestSupport.swift`'s convention of shared, `internal`
// (not `private`) helpers for a suite split across multiple files purely
// to stay under SwiftLint's per-file/per-type length limits.

func formatterTestGeometry(
  boundingBox: CGRect = CGRect(x: 0.40, y: 0.45, width: 0.20, height: 0.30),
  eyeMidpoint: CGPoint = CGPoint(x: 0.50, y: 0.62),
  interocularDistance: CGFloat = 0.11,
  yaw: Float = 0,
  pitch: Float = 0,
  roll: Float = 0,
  confidence: Float = 0.95
) -> FaceGeometry {
  FaceGeometry(
    boundingBox: boundingBox,
    eyeMidpoint: eyeMidpoint,
    interocularDistance: interocularDistance,
    yaw: yaw,
    pitch: pitch,
    roll: roll,
    captureQuality: nil,
    confidence: confidence
  )
}

func formatterTestLighting(
  faceLuma: Float = 0.5,
  backgroundLuma: Float = 0.5,
  backlightDelta: Float = 0,
  clippedHighlightFraction: Float = 0,
  clippedShadowFraction: Float = 0,
  sharpness: Float = 0.5,
  frameLumaVariance: Float = 0.01
) -> LightingMetrics {
  LightingMetrics(
    faceLuma: faceLuma,
    backgroundLuma: backgroundLuma,
    backlightDelta: backlightDelta,
    clippedHighlightFraction: clippedHighlightFraction,
    clippedShadowFraction: clippedShadowFraction,
    colorTempSkew: 0,
    sharpness: sharpness,
    frameLumaVariance: frameLumaVariance
  )
}

func formatterTestOutput(
  signalState: SignalState = .ok,
  faceCount: Int = 1,
  primary: FaceGeometry?,
  lighting: LightingMetrics,
  framing: FramingState?
) -> EngineOutput {
  let analysis = FrameAnalysis(
    timestamp: CMTime(value: 0, timescale: 30),
    signalState: signalState,
    faceCount: faceCount,
    primary: primary,
    lighting: lighting
  )
  return EngineOutput(analysis: analysis, framing: framing)
}

func formatterTestFraming(
  errorX: Float = 0,
  errorY: Float = 0,
  distanceError: Float = 0,
  inDeadZone: Bool = true,
  gazeOnCamera: Bool = true
) -> FramingState {
  FramingState(
    error: SIMD2<Float>(errorX, errorY),
    distanceError: distanceError,
    inDeadZone: inDeadZone,
    gazeOnCamera: gazeOnCamera
  )
}
