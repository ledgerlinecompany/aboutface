import CoreGraphics

/// The §3.4 egocentric boundary: converting a backend-native
/// `RawFaceObservation` into an egocentric `FaceGeometry`. Split out of
/// `AnalysisEngine.swift` purely to keep each file a manageable size (the
/// same reasoning `LightingAnalyzer`'s file split uses); everything here is
/// still `AnalysisEngine`'s own implementation, not a separate public
/// surface. See `AnalysisEngine.swift` for the type's documented behavior
/// and scope.
extension AnalysisEngine {

  /// Yaw/pitch/roll after `egocentricPose(raw:mirror:)`'s mirror-aware
  /// mapping. A small struct rather than a tuple purely to stay under
  /// SwiftLint's tuple-arity limit; it has no life outside this file.
  struct EgocentricPose {
    let yaw: Float
    let pitch: Float
    let roll: Float
  }

  /// Converts a backend-native `RawFaceObservation` into egocentric
  /// `FaceGeometry` — the one place in `AnalysisEngine` (and, per §3.4, in
  /// the whole codebase) this conversion happens. Bounding box and eye
  /// midpoint go through `EgocentricTransform`, which is deliberately
  /// scoped to *position* only (see its own doc comment); pose sign
  /// conventions are handled separately by `egocentricPose(raw:mirror:)`
  /// below.
  static func faceGeometry(from raw: RawFaceObservation, mirror: MirrorState) -> FaceGeometry {
    let boundingBox = EgocentricTransform.egocentricRect(raw.boundingBox, mirror: mirror)

    let rawEyeMidpoint: CGPoint
    let interocularDistance: CGFloat
    if let eyePoints = raw.eyePoints, eyePoints.count >= 2 {
      let left = eyePoints[0]
      let right = eyePoints[1]
      rawEyeMidpoint = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
      // Horizontal-only separation, not full Euclidean distance across both
      // axes: eye points are normalized independently per axis (x to frame
      // width, y to frame height, per `VisionBackend`'s coordinate
      // contract), so a Euclidean distance would not be a clean "fraction
      // of frame width" without the frame's aspect ratio, which
      // `RawFaceObservation` does not carry. Horizontal separation is also
      // the conventional definition of interocular distance for a
      // (near-)upright head, matching what this measurement feeds — §4's
      // "medium close-up" distance target.
      interocularDistance = abs(right.x - left.x)
    } else {
      // Landmarks unavailable this frame — e.g. `VisionBackend`'s
      // landmarks request failed while rectangles still succeeded; its doc
      // comment calls this out as a real, best-effort-degraded case, not a
      // backend bug. Fall back to the bounding-box center so
      // `FramingState.error` still has a usable position, and report 0
      // interocular distance rather than fabricating one — matching
      // `LightingAnalyzer`'s own convention of reporting 0 `faceLuma` when
      // there is nothing to sample ("0 means 'no face region was
      // supplied,' not 'totally dark'"). `framingState(for:)` treats 0
      // here as "no measurement this frame," never as "touching the
      // camera."
      rawEyeMidpoint = CGPoint(x: raw.boundingBox.midX, y: raw.boundingBox.midY)
      interocularDistance = 0
    }

    let eyeMidpoint = EgocentricTransform.egocentricPoint(rawEyeMidpoint, mirror: mirror)
    let pose = egocentricPose(raw: raw, mirror: mirror)

    return FaceGeometry(
      boundingBox: boundingBox,
      eyeMidpoint: eyeMidpoint,
      interocularDistance: interocularDistance,
      yaw: pose.yaw,
      pitch: pose.pitch,
      roll: pose.roll,
      captureQuality: raw.captureQuality,
      confidence: raw.confidence
    )
  }

  /// Maps a backend's raw yaw/pitch/roll into `FaceGeometry`'s documented
  /// egocentric sign conventions (§3.3: "+yaw = subject's head turned to
  /// their right," "+pitch = chin up," "+roll = subject's head tilted to
  /// their right").
  ///
  /// ## Empirical basis
  ///
  /// ALL THREE raw sign conventions are now established by controlled
  /// live-camera tests (deliberate head movement watched against raw
  /// values) — the only ground-truth method that has survived contact with
  /// reality. Two earlier photo-derived readings were both wrong: pitch
  /// (corrected 2026-08-01: the reference image conflated eye gaze with
  /// head pitch) and then yaw (corrected later the same day: masked
  /// three-quarter faces were misread; the live test "nose toward right
  /// shoulder" read as own-left under the photo-derived mapping while
  /// horizontal position remained correct, isolating the error to the
  /// convention, not the capture path). See
  /// `Fixtures/corpus/stills/ATTRIBUTION.md` for the full correction
  /// history. Current findings:
  ///
  /// - Vision yaw: positive = the subject's head turned toward THEIR OWN
  ///   LEFT (in an unmirrored image).
  /// - Vision pitch: positive = chin DOWN.
  /// - Vision roll: assumed positive = tilt toward the subject's own LEFT,
  ///   by the same in-image-plane logic as yaw. UNVERIFIED by a controlled
  ///   live tilt — flagged for the maintainer's ear-to-shoulder check and
  ///   the §14 head-tilt corpus clip.
  /// - A horizontal flip of the image negates yaw and roll, and leaves
  ///   pitch unchanged (synthetic flip-consistency test; robust across all
  ///   the sign corrections, since it is a relative property).
  ///
  /// ## Consequence for this mapping
  ///
  /// §3.3 wants "+ = own right / chin up / tilt right." Vision's raw
  /// positives are own-left / chin-down / tilt-left, so for `.notMirrored`
  /// frames ALL THREE axes are negated. For `.mirrored` frames the pixels
  /// handed to Vision were already flipped before inference ran (see
  /// `FileCaptureSource.simulateMirrored`), which negates raw yaw and roll
  /// once already — so yaw/roll pass through unchanged there, while pitch
  /// (mirror-invariant) is negated in both states.
  ///
  /// `nil` fields (a backend without `.headPose`, or a best-effort
  /// per-field failure) default to 0 — `FaceGeometry.yaw/pitch/roll` are
  /// non-optional. 0 is documented here as "no evidence of rotation," not
  /// "confirmed facing the camera"; a future consumer that would treat a
  /// bare 0 as high-confidence gaze-on-camera should cross-check
  /// `capabilities`/`captureQuality` first.
  static func egocentricPose(raw: RawFaceObservation, mirror: MirrorState) -> EgocentricPose {
    let rawYaw = raw.yaw ?? 0
    let rawPitch = raw.pitch ?? 0
    let rawRoll = raw.roll ?? 0
    switch mirror {
    case .notMirrored:
      return EgocentricPose(yaw: -rawYaw, pitch: -rawPitch, roll: -rawRoll)
    case .mirrored:
      return EgocentricPose(yaw: rawYaw, pitch: -rawPitch, roll: rawRoll)
    }
  }
}
