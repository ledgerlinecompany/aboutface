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

    /// §12.2/§16.4 rising-edge camera-in-use reminder ("Camera in use.
    /// Monitor is off.", `Lexicon.Reminder.cameraInUseMonitorOff`):
    /// master on/off switch for `CameraReminderStateMachine`'s `isEnabled`
    /// gate (§0/§11: every tunable lives in `Config`, never a hardcoded
    /// `true`). Default `true` — the PR brief's decided default. Flipping
    /// this off mid-episode does not retroactively announce a suppressed
    /// edge; see `CameraReminderStateMachine`'s doc comment for why that is
    /// the same rule applied to every one of its gates, not a special case.
    public var monitorReminderEnabled: Bool

    /// §12.2 field finding (2026-08-04): delay, milliseconds, between the
    /// reminder's rising edge settling and the phrase actually being
    /// spoken. The maintainer's verbatim feedback after live-testing the
    /// reminder: "Might be worth a 1-2 second delay just because you're
    /// usually hearing stuff right when the camera starts being used" — a
    /// call starting is itself an audio-busy moment (join tones, the app's
    /// own chime, people saying hello), and a reminder landing in the
    /// middle of that is easy to miss or talk over. Default `1500` sits in
    /// the middle of his 1-2s range; tunable by ear later (§0/§11: starting
    /// point, not a fixed constant). `CameraReminderStateMachine` re-reads
    /// `isCapturing`/`isSilenced`/`isEnabled`/the busy signal itself at the
    /// END of this delay, not just at the edge — see that type's doc
    /// comment for why a delay this long makes stale-gate re-validation
    /// mandatory rather than optional.
    public var reminderDelayMs: Int

    /// §12.3 mismatch warning: master on/off switch for
    /// `CameraMismatchStateMachine`'s `isEnabled` gate (§0/§11: every
    /// tunable lives in `Config`, never a hardcoded `true`). Default `true`
    /// — the PR brief's decided default. Unlike `monitorReminderEnabled`,
    /// disabling this does NOT need any "does not retroactively announce"
    /// footnote: `CameraMismatchStateMachine.Outcome` is a live status
    /// read, not a one-shot utterance, so flipping this back on shows
    /// whatever is currently true immediately — see that type's doc
    /// comment ("Why `isEnabled` is a live gate, not part of the episode").
    public var cameraMismatchWarningEnabled: Bool

    /// §12.4 virtual-camera warning: master on/off switch, same shape and
    /// same §0/§11 reasoning as `cameraMismatchWarningEnabled` above.
    /// Default `true`.
    public var virtualCameraWarningEnabled: Bool

    /// §12.5 Center Stage awareness: master on/off switch for the whole
    /// feature (beacon suppression, spoken-framing suppression, good-zone
    /// chime suppression, and the rising/falling-edge notice itself), same
    /// shape and same §0/§11 reasoning as `cameraMismatchWarningEnabled`/
    /// `virtualCameraWarningEnabled` above. Default `true` — the PR brief's
    /// decided default. Unlike those two, disabling this is NOT scoped to
    /// "stop announcing" while some internal state keeps tracking Center
    /// Stage in the background: `FeedbackRouter.setCenterStageActive(_:at:)`
    /// forces `centerStageActive` itself to `false` whenever this is off, so
    /// every suppression point downstream (the beacon, spoken framing,
    /// good-zone entry) sees a router that behaves exactly as if Center
    /// Stage did not exist — see that method's own doc comment for why
    /// gating the STATE, not just the notice, is what keeps three separate
    /// call sites from each needing their own copy of this check.
    public var centerStageAwarenessEnabled: Bool

    /// §12.4: "surface a one-time acknowledgeable warning." The set of
    /// `AVCaptureDevice.uniqueID`s the user has already acknowledged as
    /// known-virtual, persisted so the acknowledgement survives relaunch —
    /// "one-time" means once ever, not once per launch.
    ///
    /// Keyed **per device**, deliberately, rather than a single global "I
    /// know about virtual cameras" flag: acknowledging OBS must not silently
    /// suppress the warning for a DIFFERENT virtual camera selected later.
    /// That would turn a one-time acknowledgement into a permanent blindfold
    /// against exactly the §12.4 failure it exists to surface — every
    /// framing verdict silently describing an image nobody sees.
    ///
    /// An array rather than a `Set` purely for `Codable` shape: a JSON array
    /// round-trips through `ConfigStore` and is readable/editable by hand in
    /// an exported profile, which a `Set` also would be, but the array's
    /// ordering-stable encoding keeps exported profiles diffable. Membership
    /// tests are on a handful of IDs at UI speed, never a hot path.
    public var acknowledgedVirtualCameraIDs: [String]

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
      monitorReminderEnabled: Bool = true,
      reminderDelayMs: Int = 1500,
      cameraMismatchWarningEnabled: Bool = true,
      virtualCameraWarningEnabled: Bool = true,
      centerStageAwarenessEnabled: Bool = true,
      acknowledgedVirtualCameraIDs: [String] = [],
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
      self.monitorReminderEnabled = monitorReminderEnabled
      self.reminderDelayMs = reminderDelayMs
      self.cameraMismatchWarningEnabled = cameraMismatchWarningEnabled
      self.virtualCameraWarningEnabled = virtualCameraWarningEnabled
      self.centerStageAwarenessEnabled = centerStageAwarenessEnabled
      self.acknowledgedVirtualCameraIDs = acknowledgedVirtualCameraIDs
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
