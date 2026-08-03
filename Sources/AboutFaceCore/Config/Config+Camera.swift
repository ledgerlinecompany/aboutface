/// `Config.Camera` (§12.1 selection, §12.2 in-use gating). Split out of
/// `Config.swift` into this file purely to stay under SwiftLint's
/// `file_length` limit — same precedent as `Config+Audio.swift` et al (see
/// that file's doc comment): this is still a `Config`-nested type
/// (`Config.Camera`), declared via `extension Config { ... }`, exactly as
/// if it lived inline in `Config.swift`. The stored property
/// (`Config.camera`) and memberwise-init wiring stay in `Config.swift`
/// itself, per house style.
extension Config {
  /// §12.1 camera selection and §12.2 camera-in-use gating tunables. See
  /// `Capture/CameraGating.swift` (the pure gating state machine) and
  /// `Capture/AVCaptureDeviceBusyProvider.swift` (the platform probe) for
  /// what consumes these.
  public struct Camera: Codable, Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID` of the user's explicitly selected camera
    /// (§12.1: "User explicitly selects the camera"). `nil` means "system
    /// default" — resolved by whatever opens the capture session (e.g.
    /// `CameraCaptureSource.defaultDevice`), not by this type. Per-profile
    /// storage is Phase 5 (§13); this is just the field for now.
    public var selectedCameraID: String?

    /// §12.2 gating debounce, milliseconds: how long the selected device's
    /// `isInUseByAnotherApplication` signal must hold its new value before
    /// `CameraGatingStateMachine` emits a mode-transition event — the
    /// hysteresis-and-dwell requirement (§4, §7) applied to this signal, so
    /// a device flapping during app startup (or a marginal USB webcam
    /// bouncing the in-use flag) does not bounce modes. Default `2000` is a
    /// starting point (§0), not a fixed constant.
    public var busyDebounceMs: Int

    /// §12.2 "poll at 1 Hz" fallback cadence, seconds. Only used by
    /// `AVCaptureDeviceBusyProvider` when the KVO path is unavailable or
    /// `forceBusyPolling` overrides it. Default `1.0` matches the spec's
    /// own starting point.
    public var busyPollIntervalSeconds: Double

    /// Forces `AVCaptureDeviceBusyProvider` onto the polling path even
    /// though it always attempts KVO registration on
    /// `isInUseByAnotherApplication` first (and that registration, per
    /// Apple's `@objc dynamic` declaration, always succeeds — see that
    /// type's doc comment for why "registered" is not the same claim as
    /// "fires correctly"). This is the escape hatch for what only a live,
    /// two-process verification can show: if KVO registers but a real
    /// conferencing app grabbing the camera never triggers a change
    /// notification, flip this rather than rewriting the provider. Default
    /// `false`.
    public var forceBusyPolling: Bool

    /// §5.1/§5.2 per-mode capture + analysis settings: one
    /// `CameraModeCaptureSettings` value per `FeedbackMode` case, following
    /// the SAME per-mode-fields shape `FeedbackConfig.setup`/`.monitor`
    /// (`ModeLimits`) already uses, rather than inventing a parallel
    /// pattern (§0/§11: "no numeric threshold is hardcoded... every
    /// constant lives in the versioned Config struct"). Replaces
    /// `PipelineModel`'s former `setupWidth`/`setupHeight`/`setupFrameRate`
    /// private statics, whose own doc comment flagged them as placeholders
    /// "since Setup and Monitor modes want different values and
    /// mode-specific wiring hasn't landed yet" — this is that wiring.
    ///
    /// `CameraModeCaptureSettings` is declared top-level below, NOT nested
    /// inside `Camera` the way `FeedbackConfig.ModeLimits` nests inside
    /// `FeedbackConfig` — `Camera` itself is already one level of nesting
    /// inside `Config` (via this `extension Config { ... }`), and
    /// SwiftLint's `nesting` rule caps depth at one level; `FeedbackConfig`
    /// is not itself nested in `Config`'s namespace, so `ModeLimits` had
    /// room `Camera` does not.
    public var setup: CameraModeCaptureSettings
    /// §5.2: "Capture format 640×480 @ 15fps — requested explicitly, not
    /// negotiated," analysis decimated to 5 Hz (`analysisHz`) for CPU/thermal
    /// reasons over a two-hour call.
    public var monitor: CameraModeCaptureSettings

    public init(
      selectedCameraID: String? = nil,
      busyDebounceMs: Int = 2000,
      busyPollIntervalSeconds: Double = 1.0,
      forceBusyPolling: Bool = false,
      setup: CameraModeCaptureSettings = CameraModeCaptureSettings(
        width: 1280, height: 720, frameRate: 30, analysisHz: nil
      ),
      monitor: CameraModeCaptureSettings = CameraModeCaptureSettings(
        width: 640, height: 480, frameRate: 15, analysisHz: 5
      )
    ) {
      self.selectedCameraID = selectedCameraID
      self.busyDebounceMs = busyDebounceMs
      self.busyPollIntervalSeconds = busyPollIntervalSeconds
      self.forceBusyPolling = forceBusyPolling
      self.setup = setup
      self.monitor = monitor
    }

    /// Config-keyed per-mode lookup — the same "mode selects the value"
    /// shape as `FeedbackRouter.nFrameThreshold`
    /// (`mode == .setup ? feedbackConfig.nFrameSetup : feedbackConfig.nFrameMonitor`),
    /// here for capture format instead of announcement suppression.
    public func settings(for mode: FeedbackMode) -> CameraModeCaptureSettings {
      switch mode {
      case .setup: return setup
      case .monitor: return monitor
      }
    }
  }
}

/// One mode's capture format plus its target analysis rate (§5.1, §5.2) —
/// `Config.Camera.setup`/`.monitor`'s value type. Declared top-level rather
/// than nested inside `Config.Camera` purely to respect SwiftLint's
/// `nesting` depth limit; see `Config.Camera.setup`'s doc comment for why.
public struct CameraModeCaptureSettings: Codable, Sendable, Equatable {
  /// Requested capture width, pixels.
  public var width: Int
  /// Requested capture height, pixels.
  public var height: Int
  /// Requested capture frame rate, fps.
  public var frameRate: Double
  /// Target rate, Hz, at which `AnalysisEngine.stream(from:)` actually
  /// invokes the backend — independent of `frameRate`, since §5.2 captures
  /// at 15fps but analyzes at 5Hz (`AnalysisRateDecimator` drops the other
  /// two thirds of frames BEFORE the backend call, never
  /// analyze-then-discard). `nil` (or non-positive) means "analyze every
  /// captured frame" — Setup's behavior, where the capture rate already
  /// equals the desired analysis rate so no decimation is needed.
  public var analysisHz: Double?

  public init(width: Int, height: Int, frameRate: Double, analysisHz: Double?) {
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.analysisHz = analysisHz
  }
}
