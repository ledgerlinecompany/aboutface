/// Whether the currently active capture session is delivering a horizontally
/// mirrored image (`AVCaptureConnection.isVideoMirrored == true`) or the raw,
/// unmirrored sensor image.
///
/// Per spec §3.4, this MUST be set explicitly at capture session configuration
/// — never inherited from the platform default, which varies by device and OS
/// version — and threaded through every coordinate transform between backend
/// output and egocentric `FaceGeometry`. No downstream code may assume a
/// mirror state; it must always be an explicit input.
///
/// See `Analysis/EgocentricTransform.swift` for the one place this value
/// actually changes a computation.
public enum MirrorState: Sendable, Equatable {
  /// The delivered image is horizontally flipped relative to the raw sensor
  /// image, matching what the subject would see looking into a physical
  /// mirror (typical selfie/FaceTime preview convention).
  case mirrored

  /// The delivered image is the raw, unflipped sensor image.
  case notMirrored
}
