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

    public init(
      selectedCameraID: String? = nil,
      busyDebounceMs: Int = 2000,
      busyPollIntervalSeconds: Double = 1.0,
      forceBusyPolling: Bool = false
    ) {
      self.selectedCameraID = selectedCameraID
      self.busyDebounceMs = busyDebounceMs
      self.busyPollIntervalSeconds = busyPollIntervalSeconds
      self.forceBusyPolling = forceBusyPolling
    }
  }
}
