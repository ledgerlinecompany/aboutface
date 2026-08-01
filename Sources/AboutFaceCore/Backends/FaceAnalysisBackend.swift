/// A compile-time face analysis backend conformance (spec §3.2).
///
/// Backends are selected at runtime from a set compiled in at build time —
/// there is **no dynamic loading**, per the App Store's library-validation and
/// hardened-runtime constraints (§2, §3.2).
///
/// v1 ships one conformance, `VisionBackend`. Future conformances
/// (`ARKitBackend`, `MediaPipeBackend`) are out of v1 scope, but this protocol
/// MUST NOT be shaped in a way that assumes Vision's specific landmark
/// topology, coordinate origin, or pose sign conventions. In particular:
///
/// - Do not add API surface that exposes Vision landmark indices/topology
///   directly; `RawFaceObservation` is the backend-neutral output shape.
/// - Do not assume any particular coordinate origin (top-left vs. bottom-left)
///   or axis direction in `RawFaceObservation`'s coordinates — those are
///   backend-native and get normalized to egocentric coordinates exactly once,
///   at the boundary described in §3.4 (`Analysis/EgocentricTransform.swift`).
/// - Do not assume Vision's sign conventions for yaw/pitch/roll; each backend
///   reports in its own native convention in `RawFaceObservation`, and mapping
///   to `FaceGeometry`'s documented egocentric sign conventions happens in
///   `AnalysisEngine`, not in the protocol shape.
public protocol FaceAnalysisBackend: Sendable {
  /// Stable, lowercase identifier used to key `Config` overrides per backend
  /// (§3.2: "numeric thresholds do not transfer between backends").
  static var identifier: String { get }

  /// Human-readable name for display in the debug panel / settings UI.
  static var displayName: String { get }

  /// Whether this backend can run on the current hardware/OS (gated, not a
  /// static constant everywhere — e.g. a future ARKit backend would report
  /// `false` on hardware without the required sensors).
  static var isAvailable: Bool { get }

  /// The capabilities this backend instance supports. May vary by instance
  /// configuration even for a fixed backend type.
  var capabilities: BackendCapabilities { get }

  /// Analyzes one captured frame and returns a backend-native observation,
  /// or `nil` if no face was found. Coordinates in the result are in this
  /// backend's native space — not yet egocentric.
  func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation?
}

/// Declares which optional signals a `FaceAnalysisBackend` can produce.
/// See spec §3.2 for the full rationale; this is copied verbatim.
public struct BackendCapabilities: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let headPose = BackendCapabilities(rawValue: 1 << 0)

  /// True gaze tracking, not a head-pose proxy.
  public static let gaze = BackendCapabilities(rawValue: 1 << 1)

  public static let metricDistance = BackendCapabilities(rawValue: 1 << 2)
  public static let captureQuality = BackendCapabilities(rawValue: 1 << 3)
  public static let multiFace = BackendCapabilities(rawValue: 1 << 4)
}
