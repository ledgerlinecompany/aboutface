import CoreGraphics
import CoreMedia

// MARK: - Spec §3.3 signal types (verbatim shapes — do not reshape without
// updating docs/spec.md; field names and doc comments below are taken
// directly from the spec).

public struct FrameAnalysis: Sendable {
  public let timestamp: CMTime
  public let signalState: SignalState
  public let faceCount: Int
  public let primary: FaceGeometry?
  public let lighting: LightingMetrics

  public init(
    timestamp: CMTime,
    signalState: SignalState,
    faceCount: Int,
    primary: FaceGeometry?,
    lighting: LightingMetrics
  ) {
    self.timestamp = timestamp
    self.signalState = signalState
    self.faceCount = faceCount
    self.primary = primary
    self.lighting = lighting
  }
}

public enum SignalState: Sendable, Equatable {
  case ok
  /// Face probably there, detector unsure — often = too dark.
  case lowConfidence
  /// Frame looks normal, no face in it.
  case noFace
  /// Near-uniform frame: lens covered, camera asleep, feed dead.
  case noSignal
}

public struct FaceGeometry: Sendable {
  /// Normalized, EGOCENTRIC (see §3.4).
  public let boundingBox: CGRect
  /// Normalized.
  public let eyeMidpoint: CGPoint
  /// Normalized to frame width.
  public let interocularDistance: CGFloat
  /// Degrees, + = subject's head turned to their right.
  public let yaw: Float
  /// Degrees, + = chin up.
  public let pitch: Float
  /// Degrees, + = subject's head tilted to their right.
  public let roll: Float
  /// Vision's scalar, 0...1, nil if unsupported.
  public let captureQuality: Float?
  public let confidence: Float

  public init(
    boundingBox: CGRect,
    eyeMidpoint: CGPoint,
    interocularDistance: CGFloat,
    yaw: Float,
    pitch: Float,
    roll: Float,
    captureQuality: Float?,
    confidence: Float
  ) {
    self.boundingBox = boundingBox
    self.eyeMidpoint = eyeMidpoint
    self.interocularDistance = interocularDistance
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.captureQuality = captureQuality
    self.confidence = confidence
  }
}

public struct LightingMetrics: Sendable {
  /// Mean luma, face ROI, 0...1.
  public let faceLuma: Float
  /// Mean luma, frame minus face ROI.
  public let backgroundLuma: Float
  /// backgroundLuma - faceLuma; high = backlit.
  public let backlightDelta: Float
  public let clippedHighlightFraction: Float
  public let clippedShadowFraction: Float
  /// -1 (cool) ... +1 (warm).
  public let colorTempSkew: Float
  /// Variance of Laplacian, face ROI, normalized.
  public let sharpness: Float
  /// For noSignal detection.
  public let frameLumaVariance: Float

  public init(
    faceLuma: Float,
    backgroundLuma: Float,
    backlightDelta: Float,
    clippedHighlightFraction: Float,
    clippedShadowFraction: Float,
    colorTempSkew: Float,
    sharpness: Float,
    frameLumaVariance: Float
  ) {
    self.faceLuma = faceLuma
    self.backgroundLuma = backgroundLuma
    self.backlightDelta = backlightDelta
    self.clippedHighlightFraction = clippedHighlightFraction
    self.clippedShadowFraction = clippedShadowFraction
    self.colorTempSkew = colorTempSkew
    self.sharpness = sharpness
    self.frameLumaVariance = frameLumaVariance
  }
}

/// Derived by `AnalysisEngine` from `FaceGeometry` and `Config`'s target
/// framing (§3.3).
public struct FramingState: Sendable {
  /// Normalized offset from target, egocentric.
  /// x: + = subject is right of target.
  /// y: + = subject is above target.
  public let error: SIMD2<Float>
  /// + = too close.
  public let distanceError: Float
  /// Hysteresis-latched (§4, §7.1): `true` only when horizontal, vertical,
  /// AND distance error are ALL within `Config.DeadZone`'s entry thresholds;
  /// flips back to `false` the instant ANY one of the three exceeds its
  /// (wider) exit threshold. Distance joined this latch 2026-08-02 — see
  /// `Config.DeadZone.distance`'s doc comment and
  /// `AnalysisEngine.updatedDeadZoneLatch(error:distanceError:)` — because
  /// distance used to be excluded, so a laterally-centered subject went
  /// silent (losing the only distance cue §6.2 has) even with distance still
  /// far off target.
  public let inDeadZone: Bool
  /// From yaw/pitch magnitude, or true gaze if available.
  public let gazeOnCamera: Bool
  /// `|roll − learned roll baseline| <= Config.Gaze.maxRollDegrees` (§4
  /// extension, maintainer 2026-08-02: "Agreed, it's part of gaze" — roll
  /// joins the same learned-baseline machinery as `gazeOnCamera`, see
  /// `AnalysisEngine+GazeBaseline.swift`). **ADVISORY ONLY — deliberately
  /// NOT part of `inDeadZone`.** Head tilt is a pose problem, not a
  /// placement one: there is no rotational axis in the positional
  /// sonification for the beacon to guide a tilt correction with, so a
  /// held tilt while otherwise well-placed still enters and stays in the
  /// good zone; `headLevel == false` only ever surfaces as
  /// `FeedbackRouter`'s in-zone advisory (`Lexicon.Instruction.level`),
  /// mirroring how `gazeOnCamera` itself moved out of the good-zone gate
  /// for the identical reason. Additive field (default `true`, "level")
  /// so pre-existing `FramingState(...)` call sites keep compiling.
  public let headLevel: Bool

  public init(
    error: SIMD2<Float>, distanceError: Float, inDeadZone: Bool, gazeOnCamera: Bool,
    headLevel: Bool = true
  ) {
    self.error = error
    self.distanceError = distanceError
    self.inDeadZone = inDeadZone
    self.gazeOnCamera = gazeOnCamera
    self.headLevel = headLevel
  }
}

// MARK: - Backend-neutral raw observation

/// A `FaceAnalysisBackend`'s raw, pre-normalization output.
///
/// The spec (§3.2) references this type as `FaceAnalysisBackend.analyze(_:)`'s
/// return value but does not define its shape, so it is defined here to be
/// deliberately backend-neutral:
///
/// - `boundingBox`, `landmarks`, and `eyePoints` are in the **backend's own
///   native normalized coordinate space** — origin corner, axis direction,
///   and any mirroring are backend-specific and NOT assumed here. This is
///   *pre*-egocentric-normalization output; see
///   `Analysis/EgocentricTransform.swift` and spec §3.4 for the one place
///   these get converted to egocentric `FaceGeometry` coordinates.
/// - `landmarks`/`eyePoints` are optional and backend-specific in count and
///   topology (per §3.2, `FaceAnalysisBackend` must not assume Vision's
///   landmark topology); a backend that does not expose per-landmark detail
///   should leave these `nil` even if it has the `.headPose` capability.
/// - `yaw`/`pitch`/`roll` are each optional and in whatever sign convention
///   the backend natively reports; mapping to `FaceGeometry`'s documented
///   egocentric sign conventions is `AnalysisEngine`'s job, not this type's.
public struct RawFaceObservation: Sendable {
  /// Backend-native normalized bounding box. Not yet egocentric.
  public let boundingBox: CGRect

  /// Backend-native landmark points, if the backend exposes them. Topology
  /// (count, ordering, meaning) is backend-specific.
  public let landmarks: [CGPoint]?

  /// Backend-native eye center point(s), if the backend distinguishes eye
  /// detection from general landmarks.
  public let eyePoints: [CGPoint]?

  /// Degrees, backend-native sign convention.
  public let yaw: Float?
  /// Degrees, backend-native sign convention.
  public let pitch: Float?
  /// Degrees, backend-native sign convention.
  public let roll: Float?

  /// Backend's own scalar capture-quality estimate, 0...1, if supported.
  public let captureQuality: Float?

  /// Backend's confidence that this observation is a face.
  public let confidence: Float

  /// Total number of faces the backend detected in this frame — may exceed
  /// `1` even though this observation's `boundingBox`/landmarks/pose fields
  /// only describe the **primary** face (the one with the largest
  /// bounding-box area). Backends that declare `.multiFace` (§3.2) populate
  /// this with the real count; a backend without multi-face support should
  /// report `1` for any non-`nil` observation. `AnalysisEngine` reads this to
  /// populate `FrameAnalysis.faceCount` — it is not derived from the length
  /// of any array here, since `RawFaceObservation` only ever carries one
  /// face's geometry.
  public let faceCount: Int

  public init(
    boundingBox: CGRect,
    landmarks: [CGPoint]? = nil,
    eyePoints: [CGPoint]? = nil,
    yaw: Float? = nil,
    pitch: Float? = nil,
    roll: Float? = nil,
    captureQuality: Float? = nil,
    confidence: Float,
    faceCount: Int
  ) {
    self.boundingBox = boundingBox
    self.landmarks = landmarks
    self.eyePoints = eyePoints
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.captureQuality = captureQuality
    self.confidence = confidence
    self.faceCount = faceCount
  }
}
