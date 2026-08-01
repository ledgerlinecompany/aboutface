import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The v1 `FaceAnalysisBackend` conformance, backed by macOS 15's Swift-native
/// Vision API (`DetectFaceRectanglesRequest`, `DetectFaceLandmarksRequest`,
/// `DetectFaceCaptureQualityRequest` — see spec §3.2).
///
/// ## Coordinate contract (spec §3.2 note, §3.4)
///
/// Everything this backend writes into `RawFaceObservation` is in **Vision's
/// native raw image space**: normalized `0...1`, origin at the image's
/// **bottom-left** corner. This is Vision's own convention — every
/// `Vision.NormalizedRect`/`Vision.NormalizedPoint` value defaults to
/// `CoordinateOrigin.lowerLeft` when asked to convert to pixel coordinates —
/// and this type passes it through unchanged rather than flipping to a
/// top-left convention.
///
/// This backend performs **no** mirror or egocentric handling. Per §3.4 that
/// conversion happens exactly once, at the backend → `FaceGeometry` boundary
/// (`Analysis/EgocentricTransform.swift`), driven by the frame's
/// `MirrorState`. Any future backend conformance (`ARKitBackend`,
/// `MediaPipeBackend`) MUST convert its own native coordinate space INTO this
/// same raw-image-space contract — normalized `0...1`, bottom-left origin —
/// before returning a `RawFaceObservation`, so `AnalysisEngine` never has to
/// know which backend produced a given observation.
///
/// ## Pose sign convention — UNVERIFIED, flagged for empirical confirmation
///
/// `yaw`/`pitch`/`roll` are Vision's own `FaceObservation.yaw/.pitch/.roll`
/// (each a non-optional `Measurement<UnitAngle>` in the current SDK),
/// converted to degrees with no sign change. Vision's public documentation
/// states only the rotation *axis* for each ("rotational angle of the face
/// around the {x,y,z}-axis") and does not commit, in prose, to a sign
/// convention (clockwise vs. counterclockwise, or which screen-relative
/// direction is positive) — this is a known gap in Apple's docs, not an
/// oversight here. Community-reported (but Apple-unverified) convention for
/// the legacy `VNFaceObservation` equivalents, which this API is built on top
/// of, is: positive roll = counterclockwise as viewed in the (unmirrored)
/// image; positive yaw = face turned toward the image's right edge; positive
/// pitch = chin up. Treat that as a **starting hypothesis only**. Per spec
/// §3.4 this is the single worst failure mode available to this project, so
/// `AnalysisEngine`'s mapping of these raw values to `FaceGeometry`'s
/// documented egocentric sign conventions MUST be confirmed empirically
/// against a real face (e.g. the `Fixtures/corpus/clips/test-face` fixture
/// described in `VisionBackendTests.detectsRealFaceWhenFixturePresent()`,
/// once populated) before being trusted, not assumed from this comment.
///
/// ## "No face" contract
///
/// Per `FaceAnalysisBackend.analyze(_:)`'s doc comment, `nil` means "no face
/// found in an otherwise-successfully-processed frame." This backend returns
/// `nil` whenever `DetectFaceRectanglesRequest` succeeds with zero
/// observations — `RawFaceObservation` is never constructed with a `nil`
/// bounding box, so there is no "zero-face observation" value; `nil` is the
/// only spelling of "no face." `analyze(_:)` only *throws* for genuine Vision
/// failures (a malformed pixel buffer, an internal Vision error) surfaced by
/// the rectangles request — that's the one request whose failure means "we
/// don't know anything about this frame," as opposed to landmarks/
/// capture-quality failures below, which just degrade an
/// already-successful detection rather than invalidate it.
public struct VisionBackend: FaceAnalysisBackend {
  public static let identifier = "vision"
  public static let displayName = "Apple Vision"

  /// The Swift-native Vision face request types used here
  /// (`DetectFaceRectanglesRequest` et al.) are marked `@available(macOS
  /// 15.0, ...)`. `Package.swift` already sets a macOS 15 platform floor, so
  /// there is no older-OS fallback path for this backend to gate on at
  /// runtime — it is unconditionally available wherever this package runs.
  public static let isAvailable = true

  /// Vision reports 2D head pose (`.headPose`) and a scalar capture-quality
  /// score via `DetectFaceCaptureQualityRequest` (`.captureQuality`), and
  /// `DetectFaceRectanglesRequest` returns every face it finds, so
  /// `RawFaceObservation.faceCount` can report more than one even though
  /// only the primary face is mapped (`.multiFace`). Vision does not provide
  /// true gaze tracking distinct from head-pose (`.gaze`) or metric
  /// (real-world-units) distance (`.metricDistance`).
  public let capabilities: BackendCapabilities = [.headPose, .captureQuality, .multiFace]

  public init() {}

  public func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation? {
    // Rectangles is the one request whose failure is "genuine" per this
    // type's doc comment above: let it propagate as-is (bad pixel buffer,
    // Vision internal error, etc.) rather than swallowing it into a result
    // that would look identical to "no face in an otherwise-healthy frame."
    let rectanglesRequest = DetectFaceRectanglesRequest()
    let faces = try await rectanglesRequest.perform(on: frame.pixelBuffer)

    guard let primary = faces.max(by: { Self.area(of: $0) < Self.area(of: $1) }) else {
      return nil
    }

    // Landmarks (for eye positions) are best-effort: per spec point 3, a
    // landmarks failure degrades the observation (nil eye fields) rather
    // than failing the whole analyze — the rectangles request already
    // succeeded, so we do have a face.
    let landmarksObservation = await Self.primaryObservation(
      matching: primary.uuid,
      from: Self.landmarks(for: faces, on: frame.pixelBuffer)
    )
    let eyePoints = Self.eyePoints(from: landmarksObservation)

    // Capture quality is likewise best-effort (spec point 4): nil on
    // failure, never fails the whole analyze.
    let qualityObservation = await Self.primaryObservation(
      matching: primary.uuid,
      from: Self.captureQuality(for: faces, on: frame.pixelBuffer)
    )

    return RawFaceObservation(
      boundingBox: primary.boundingBox.cgRect,
      landmarks: nil,
      eyePoints: eyePoints,
      yaw: Float(primary.yaw.converted(to: .degrees).value),
      pitch: Float(primary.pitch.converted(to: .degrees).value),
      roll: Float(primary.roll.converted(to: .degrees).value),
      captureQuality: qualityObservation?.captureQuality?.score,
      confidence: primary.confidence,
      faceCount: faces.count
    )
  }

  /// Runs `DetectFaceLandmarksRequest` against the already-detected `faces`
  /// (via `inputFaceObservations`, so Vision refines the existing regions
  /// rather than re-running whole-frame face detection). Returns `nil` on
  /// any failure — a landmarks failure must not fail `analyze(_:)` as a
  /// whole (spec point 3).
  private static func landmarks(
    for faces: [FaceObservation],
    on pixelBuffer: CVPixelBuffer
  ) async -> [FaceObservation]? {
    var request = DetectFaceLandmarksRequest()
    request.inputFaceObservations = faces
    return try? await request.perform(on: pixelBuffer)
  }

  /// Runs `DetectFaceCaptureQualityRequest` against the already-detected
  /// `faces`. Returns `nil` on any failure — a capture-quality failure must
  /// not fail `analyze(_:)` as a whole (spec point 4).
  private static func captureQuality(
    for faces: [FaceObservation],
    on pixelBuffer: CVPixelBuffer
  ) async -> [FaceObservation]? {
    var request = DetectFaceCaptureQualityRequest()
    request.inputFaceObservations = faces
    return try? await request.perform(on: pixelBuffer)
  }

  /// `inputFaceObservations`-driven requests return one `FaceObservation`
  /// per input face, correlated by `uuid`; this finds the one matching the
  /// primary face selected in `analyze(_:)`.
  private static func primaryObservation(
    matching uuid: UUID,
    from observations: [FaceObservation]?
  ) -> FaceObservation? {
    observations?.first { $0.uuid == uuid }
  }

  /// Bounding-box area, used only to rank faces by size when picking the
  /// primary observation.
  private static func area(of observation: FaceObservation) -> CGFloat {
    observation.boundingBox.width * observation.boundingBox.height
  }

  /// Eye centers in Vision's raw image space (see the coordinate-contract
  /// doc comment above): `[leftEyeCenter, rightEyeCenter]`, in that fixed
  /// order. `nil` if landmarks weren't available (request failure, or no
  /// eye region reported for this face).
  ///
  /// Vision reports landmark points normalized **to the face's own
  /// bounding box** (`0...1` within that box), not to the full image — the
  /// same convention the legacy `VNFaceLandmarkRegion2D` API used. Each
  /// point is therefore mapped into full-image-normalized space via
  /// `boundingBox.origin + localPoint * boundingBox.size` before being
  /// returned, so every point `VisionBackend` emits (bounding box and eye
  /// points alike) is consistently in the same raw image space.
  private static func eyePoints(from observation: FaceObservation?) -> [CGPoint]? {
    guard let observation, let landmarks = observation.landmarks else {
      return nil
    }
    let boundingBox = observation.boundingBox.cgRect
    guard
      let leftCenter = averageImagePoint(landmarks.leftEye.points, in: boundingBox),
      let rightCenter = averageImagePoint(landmarks.rightEye.points, in: boundingBox)
    else {
      return nil
    }
    return [leftCenter, rightCenter]
  }

  /// Averages a face-local-normalized landmark region's points, then maps
  /// that single average into full-image-normalized space (equivalent to,
  /// but cheaper than, mapping every point first and then averaging, since
  /// the box→image mapping is affine).
  private static func averageImagePoint(
    _ points: [NormalizedPoint],
    in boundingBox: CGRect
  ) -> CGPoint? {
    guard !points.isEmpty else {
      return nil
    }
    let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    let count = CGFloat(points.count)
    let localAverage = CGPoint(x: sum.x / count, y: sum.y / count)
    return CGPoint(
      x: boundingBox.origin.x + localAverage.x * boundingBox.width,
      y: boundingBox.origin.y + localAverage.y * boundingBox.height
    )
  }
}
