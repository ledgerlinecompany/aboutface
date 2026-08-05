// swift-format and swiftlint disagree on case-sensitive vs. case-insensitive
// import ordering (see Sources/AboutFaceCore/Capture/FileCaptureSource.swift
// for the canonical example of this same conflict); this order satisfies
// `swift format lint`, which the CI gate also enforces.
// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore
import Observation
import SwiftUI

// swiftlint:enable sorted_imports

/// The Phase 2 "live pipeline model" (spec §9/§12): owns camera
/// enumeration, the capture/engine lifecycle, `Config` load/save, and the
/// throttled state the Setup window and debug panel read from. `@MainActor`
/// because every stored property here is read directly by SwiftUI views;
/// `@Observable` so those views only re-render on the properties they
/// actually read.
///
/// Split across several files purely to stay under SwiftLint's file-length
/// limit, the same reasoning `AnalysisEngine`'s `+Framing`/`+Geometry` file
/// split uses — everywhere below is still `PipelineModel`'s own
/// implementation, not a separate public surface:
/// - `PipelineModel.swift` (this file): stored state, `init`, and the
///   capture/engine session lifecycle.
/// - `PipelineModel+Camera.swift`: explicit camera selection (§12.1) and
///   camera permission (§9/§12).
/// - `PipelineModel+Config.swift`: `Config` load/save/reset/export/import
///   and the slider `Binding` helpers (§9/§11).
/// - `PipelineModel+Target.swift`: "capture current position as target"
///   (§4).
/// - `PipelineModel+Mode.swift`: `setMode(_:)`, Setup↔Monitor (§5, §13
///   Phase 4), and the `toggleMonitor()` trigger (§16.4).
///
/// ## Two throttle rates, one upstream stream (spec §9)
///
/// `AnalysisEngine.stream(from:)` yields at the capture rate (30 Hz in
/// Setup mode, §5.1). Two independent, coarser rates are derived from it:
///
/// - `visualOutput`, ~10 Hz: drives on-screen (sighted) visual state —
///   never the full 30 Hz, per the task brief's "never 30 Hz UI churn."
/// - `accessibilitySnapshot`, ~2 Hz: backs every row's `.accessibilityValue`
///   (spec §9: "Post `.valueChanged`... throttled to ~2 Hz" — applied here
///   to the whole snapshot rather than per-focused-element; see
///   `AccessibilitySnapshot`'s doc comment for why that is a documented,
///   revisitable simplification, not an oversight).
///
/// Both are simple wall-clock throttles (`ingest(_:)` below) rather than
/// display-link-driven, since the upstream rate is already bounded by the
/// capture frame rate — there is no risk of the throttle itself becoming
/// the bottleneck.
@MainActor
@Observable
public final class PipelineModel {

  // MARK: - Camera

  public let cameraDiscovery = CameraDiscovery()
  public var selectedCameraID: String?
  // `internal(set)`, not `private(set)`: written from `requestCameraPermission()`
  // in `PipelineModel+Camera.swift` — Swift's `private` scopes to the
  // declaring *file*, not the whole type, same note as `config`'s doc
  // comment below.
  public internal(set) var permissionState: CameraPermissionState

  // MARK: - Config (§11)

  // `internal(set)`, not `private(set)`: written from `updateConfig(_:)` in
  // `PipelineModel+Config.swift` — `private` in Swift scopes to the
  // declaring *file*, not the whole type, so a setter used from another
  // extension file needs at least `internal` visibility.
  public internal(set) var config: Config
  public private(set) var configLoadIssue: ConfigStore.LoadIssue?

  // MARK: - Session lifecycle

  // `internal(set)`, not `private(set)`, on both of these: `setMode(_:)`'s
  // capture restart in `PipelineModel+Mode.swift` writes them too (Swift's
  // `private` scopes to the declaring FILE, not the whole type — see
  // `config`'s doc comment above for the same note).
  public internal(set) var isRunning = false
  public internal(set) var captureErrorMessage: String?

  /// §12.2/§16.4 reminder: set by `MonitorReminderController` when
  /// `CMIOCameraBusyProvider.init` can't resolve `selectedCameraID` — see
  /// that controller's doc comment for why this must surface visibly
  /// rather than silently leaving the reminder unarmed. `nil` when fine or
  /// not yet configured. Surfaced next to `captureErrorMessage`.
  public internal(set) var monitorReminderIssue: String?

  /// §12.3 mismatch warning: set by `CameraMismatchController` when
  /// `CameraMismatchStateMachine` decides a notice should show — a
  /// non-selected camera appears to be running, or the cross-device signal
  /// itself is unreadable (see `CameraMismatchClassifier`'s doc comment for
  /// what each case means). `nil` when clear, dismissed, disabled, or not
  /// yet configured. Deliberately a plain `String?`, the same shape
  /// `monitorReminderIssue`/`hotkeyRegistrationIssue` use — this is
  /// VoiceOver-readable text, never spoken (§12.3 is informational, not an
  /// automatic utterance; see `CameraMismatchController`'s doc comment).
  public internal(set) var cameraMismatchWarning: String?

  /// §12.4: the selected camera's name matches a known virtual-camera
  /// pattern and this device has not been acknowledged yet. `nil` when there
  /// is nothing to say. Recomputed by `refreshVirtualCameraWarning()`
  /// (`PipelineModel+Camera.swift`) on selection and device-list changes —
  /// there is no observation loop for this signal, because a device's NAME
  /// cannot change under us the way its running state can. Same
  /// plain-`String?`, VoiceOver-readable, never-spoken shape as
  /// `cameraMismatchWarning` above.
  public internal(set) var virtualCameraWarning: String?

  /// §12.5 Center Stage awareness: set by `CenterStageController` from
  /// `CenterStageStateMachine.Outcome` — a plain, always-current status
  /// readout distinguishing "Center Stage is on," "off," and "could not be
  /// determined" (the `.unknown`/`.deviceNotFound` case — see
  /// `CenterStageStateMachine`'s doc comment for why that third state must
  /// never collapse into "off"). `nil` when the feature is disabled
  /// (`Config.Camera.centerStageAwarenessEnabled == false`) or not yet
  /// configured. Same plain-`String?`, VoiceOver-readable, never-spoken
  /// shape as `cameraMismatchWarning`/`virtualCameraWarning` above — the
  /// SPOKEN half of Center Stage awareness is
  /// `FeedbackRouter.setCenterStageActive(_:at:)`'s own rising/falling-edge
  /// notice, driven by the same controller; this property is only the
  /// Setup window's VoiceOver-readable echo of the current reading.
  public internal(set) var centerStageNotice: String?

  /// §12.5 debug-panel override: forces the value
  /// `CenterStageController` feeds to
  /// `FeedbackRouter.setCenterStageActive(_:at:)`, regardless of what
  /// `CenterStageMonitor`'s poller actually reads — so the maintainer can
  /// judge Center Stage's feedback suppression by ear without depending on
  /// the poller (or real hardware) being available. `nil` (the default)
  /// means "follow the real signal"; `true`/`false` force the router
  /// unconditionally. Tri-state rather than a plain `Bool` specifically so
  /// "not overridden" is representable and distinct from "overridden to
  /// off" — a plain `Bool` defaulting to `false` would be indistinguishable
  /// from a genuine forced-off override. Deliberately NOT a `Config` field:
  /// this is a debug-only, in-memory, session-lifetime aid the maintainer
  /// may remove later during the app's presentation cleanup (see
  /// `DebugPanelView`'s Center Stage section), not a tuning value worth
  /// persisting or shipping in an exported profile. Does NOT affect
  /// `centerStageNotice` above — that stays an honest report of the real
  /// signal, specifically so the override can never be mistaken for a real
  /// reading (see `CenterStageController.overrideChanged()`'s doc comment).
  public var centerStageDebugOverride: Bool?

  /// §8: per-action `RegisterEventHotKey` failures, written by
  /// `HotkeyCenter.updateRegistrations(_:)` (see that method's doc comment
  /// for why a failure must never be silently discarded). `nil` when every
  /// binding registered cleanly; same "surface it" posture as
  /// `monitorReminderIssue` above.
  public internal(set) var hotkeyRegistrationIssue: String?

  // MARK: - Mode (§5, §13 Phase 4) — see `PipelineModel+Mode.swift`

  /// Setup vs. Monitor (§5.1/§5.2). Defaults to `.setup` — the app opens a
  /// real window and converges the user's framing before anything goes to
  /// the background. `internal(set)`, not `private(set)`, for the same
  /// cross-file-visibility reason as `config` above: written from
  /// `setMode(_:)` in `PipelineModel+Mode.swift`. Flipped in normal use by
  /// two shipping triggers: the debug panel's mode `Picker` and
  /// `toggleMonitor()` (⌘⌃⇧M / `MenuBarExtra`, both in
  /// `PipelineModel+Mode.swift`). A third trigger — auto-activation from the
  /// selected camera going busy/free — was built (`AboutFaceCore`'s
  /// `CameraGatingStateMachine`/`CameraInUseMonitor`) but is not wired in;
  /// see spec §12.2's finding and §16.4 before reviving it.
  public internal(set) var mode: FeedbackMode = .setup

  // MARK: - Feedback chain (§5.1, §13 Phase 3) — see `PipelineModel+Audio.swift`

  /// "Feedback" toggle (§5.1 task brief): on by default whenever the
  /// pipeline is running. Distinct from `isSilenced` — this is a
  /// user-facing master switch (persists across start/stop), `isSilenced`
  /// is the §7.5 "someone just started talking to me" instant mute. Both
  /// feed the same `FeedbackRouter.setSilenced(_:)` call; see
  /// `PipelineModel+Audio.swift`'s `pushSilencedState()`.
  public internal(set) var feedbackEnabled = true
  /// §7.5 manual silence (⌘⌃⇧/ in-app stand-in — see
  /// `PipelineModel+Audio.swift`'s `toggleSilence()` doc comment for why
  /// this is not yet the global `RegisterEventHotKey` §8 requires).
  public internal(set) var isSilenced = false
  /// Set when `AudioRenderer.start()` throws (no audio device, or any other
  /// startup failure) — the pipeline keeps running UI-only in that case
  /// (task brief: "a no-audio-device failure can't crash the app; feedback
  /// chain failure degrades to silent UI-only operation with a visible
  /// notice"). `nil` when audio is fine or not yet started.
  public internal(set) var audioUnavailableMessage: String?

  var audioRenderer: AudioRenderer?
  var feedbackRouter: FeedbackRouter?

  /// The single app-lifetime `SpeechRenderer` (§6.3), constructed once here
  /// in `init()`, never torn down while the app runs — shared by
  /// `startFeedbackChain()` (hands it to each fresh `FeedbackRouter`),
  /// `HotkeyCenter.dispatch(_:)` (speaks `Lexicon.Confirmation` phrases
  /// through it directly, deliberately bypassing `FeedbackRouter` — see
  /// that enum's doc comment), and `MonitorReminderController` (its
  /// `Lexicon.Reminder` phrase). One shared renderer makes overlapping
  /// speech impossible BY CONSTRUCTION, where the pre-fix design (two
  /// separate renderers) only avoided it by an argument about disjoint time
  /// windows a third speaker would have broken — see
  /// `MonitorReminderController`'s doc comment for the fuller history.
  /// `stopFeedbackChain()` deliberately does NOT discard this property
  /// (only `stopSpeaking()`) — the reminder/hotkeys need it while idle.
  public let speechRenderer: SpeechRenderer

  // MARK: - Throttled state (see type-level doc comment)

  // `internal(set)`, not `private(set)`: `PipelineModel+Ingest.swift`'s
  // `ingest(_:)` writes all three on the throttled cadence described there
  // — same cross-file-visibility note as `config`'s doc comment above.
  public internal(set) var visualOutput: EngineOutput?
  public internal(set) var accessibilitySnapshot: AccessibilitySnapshot = .empty
  public internal(set) var signalStateLine: String = "Not started"

  // MARK: - Static-per-session context fed to `SignalFormatter`

  // Same `internal(set)` note as `isRunning`/`captureErrorMessage` above:
  // `setMode(_:)`'s capture restart updates both when the format changes.
  public internal(set) var captureFormat: SignalFormatter.CaptureFormatDescriptor?
  public internal(set) var mirrorState: MirrorState?
  /// The ACTUAL pixel dimensions the camera has delivered this session,
  /// latched from the FIRST `EngineOutput` a fresh capture actually
  /// produces (`ingest(_:)`, below) — `nil` from the moment `captureFormat`
  /// is (re)assigned in `start()`/`setMode(_:)`'s capture restart until
  /// that first frame arrives. Distinct from `captureFormat` on purpose:
  /// `captureFormat` is what was REQUESTED, this is what was CONFIRMED —
  /// see `CapturedFrame.pixelDimensions`'s doc comment for why trusting the
  /// request alone reproduces PR #53's bug one layer up. Read by
  /// `SignalFormatter.snapshot`'s `.captureFormat` row, which flags a
  /// mismatch explicitly rather than silently reporting the request.
  public internal(set) var actualCaptureDimensions: PixelDimensions?
  public let backendDisplayName = VisionBackend.displayName

  // MARK: - Private engine/session state

  var captureSource: CameraCaptureSource?
  var engine: AnalysisEngine?
  var consumeTask: Task<Void, Never>?
  var saveTask: Task<Void, Never>?

  /// Bumped every time `consumeTask` is intentionally superseded or torn
  /// down (`beginConsuming(engine:source:targetAnalysisHz:)`, `stop()`) —
  /// see `beginConsuming`'s doc comment for why a superseded consume task's
  /// own completion handler must not be allowed to stomp `isRunning`/
  /// `captureErrorMessage` after a NEWER one has already taken over (the
  /// §13 Phase 4 task brief's trap (c): "two rapid calls... must not leave
  /// the model believing it is in a mode it is not").
  var captureGeneration = 0

  /// Serializes `setMode(_:)` calls into a FIFO queue — see that method's
  /// doc comment in `PipelineModel+Mode.swift` (trap (c): overlapping/
  /// re-entrant mode transitions). Starts as an already-finished no-op task
  /// so the first real `setMode` call has an immediately-satisfiable
  /// `previous` to await.
  var modeTransitionChain: Task<Void, Never> = Task {}

  /// The most recent `EngineOutput`, updated on every frame regardless of
  /// throttling — "capture current position as target" (§4) wants the
  /// freshest smoothed reading available, not whatever the ~2 Hz
  /// accessibility snapshot happens to be showing at the moment the button
  /// is pressed. Read by `PipelineModel+Target.swift`.
  var latestOutput: EngineOutput?

  // Not `private`: `ingest(_:)`/`words(for:)` moved to
  // `PipelineModel+Ingest.swift` to stay under SwiftLint's file-length
  // limit (same cross-file-visibility note as `config`'s doc comment
  // above — Swift's `private` scopes to the declaring *file*).
  var lastVisualUpdate: ContinuousClock.Instant = .now
  var lastAccessibilityUpdate: ContinuousClock.Instant = .now
  let visualInterval = Duration.milliseconds(100)  // ~10 Hz
  let accessibilityInterval = Duration.milliseconds(500)  // ~2 Hz

  public init() {
    permissionState = CameraPermissionState(AVCaptureDevice.authorizationStatus(for: .video))

    // Loaded into a LOCAL first, not straight into `self.config` — Swift's
    // two-phase class init forbids reading `self.config` until EVERY stored
    // property has a value, and `speechRenderer` below needs this same
    // loaded value before that point. A local sidesteps the restriction.
    let loadedConfig: Config
    let loadIssue: ConfigStore.LoadIssue?
    if let url = try? ConfigStore.defaultURL() {
      let result = ConfigStore.load(from: url)
      loadedConfig = result.config
      loadIssue = result.issue
    } else {
      loadedConfig = .defaults
      loadIssue = nil
    }
    config = loadedConfig
    configLoadIssue = loadIssue
    // See `speechRenderer`'s doc comment above: constructed once, here, for
    // the app's whole lifetime, seeded from the same `loadedConfig` just
    // assigned to `config`.
    speechRenderer = SpeechRenderer(config: loadedConfig.speech)

    // Auto-default ONLY — deliberately assigns `selectedCameraID` directly
    // rather than going through `selectCamera(_:)` below, and MUST keep
    // doing so. This exists so `start()` has *something* to open on a
    // fresh install with zero user interaction; it must never be persisted
    // into `Config.Camera.selectedCameraID`. If a future edit routes this
    // assignment through `selectCamera(_:)` instead, every fresh install
    // becomes `Config.isConfigured`-true (`Config+Configured.swift`) the
    // instant camera discovery finds a device — silently defeating §16.4's
    // "never auto-enable on a fresh unconfigured install" gate from the
    // opposite direction it exists to guard. See `selectCamera(_:)`'s doc
    // comment for the counterpart half of this contract. (Maintainer
    // field finding, this PR: this predicate's camera half was dead code
    // until this fix — nothing previously wrote `Config.Camera
    // .selectedCameraID` at all.)
    if selectedCameraID == nil {
      selectedCameraID = cameraDiscovery.devices.first?.id
    }
  }

  // `selectCamera(_:)` (§12.1 explicit selection) and the camera-permission
  // pair (`requestCameraPermission()`/`openSystemSettingsForCameraPrivacy()`,
  // §9/§12) live in `PipelineModel+Camera.swift`, not here, purely to stay
  // under SwiftLint's file-length limit — same split precedent as
  // `PipelineModel+Mode.swift`/`+Target.swift`/`+Config.swift` (see this
  // file's own type-level doc comment).

  // `start()`/`stop()` — the capture/engine session lifecycle — live in
  // `PipelineModel+Session.swift`, not here, for the same file-length
  // reason as the splits noted above.

  // `ingest(_:)`/`words(for:)` — the per-frame throttle that drives
  // `visualOutput`/`accessibilitySnapshot`/`signalStateLine` — live in
  // `PipelineModel+Ingest.swift`, not here, for the same file-length reason.
}
