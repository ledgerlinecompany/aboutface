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

/// Camera-permission state for the Setup window's permission flow (spec
/// §9/§12). Mirrors `AVAuthorizationStatus` with a name that reads cleanly
/// in UI code; `.restricted` (parental controls / MDM) is folded in as its
/// own case because the "ask again" affordance differs from a user-chosen
/// `.denied`.
public enum CameraPermissionState: Sendable, Equatable {
  case notDetermined
  case authorized
  case denied
  case restricted

  init(_ status: AVAuthorizationStatus) {
    switch status {
    case .authorized: self = .authorized
    case .denied: self = .denied
    case .restricted: self = .restricted
    case .notDetermined: self = .notDetermined
    @unknown default: self = .denied
    }
  }
}

/// The throttled, VoiceOver-facing view of the latest engine output — the
/// "one observable accessibility snapshot struct" the Setup window's rows
/// read from (spec §9's "Post `.valueChanged` only for the currently-
/// focused element, throttled to ~2 Hz").
///
/// Deliberately just a wrapper around `[SignalFormatter.FormattedSignal]`
/// today — every row updates in lockstep, at the same ~2 Hz cadence. This
/// is a known, documented simplification for Phase 2 (see
/// `docs/acceptance/phase2-checklist.md`): the spec's stronger form of the
/// requirement is per-*focused*-element throttling, which needs
/// `NSAccessibility` focus tracking this pass deliberately does not build
/// (per the task brief: "do not attempt per-element focus tracking...
/// validated/tuned by the human pass"). Because every row already flows
/// through this one struct, adding a per-row `lastPostedAt` (or a
/// currently-focused-field flag) later is a change to this type only — no
/// view or model rewiring required.
public struct AccessibilitySnapshot: Sendable, Equatable {
  public var rows: [SignalFormatter.FormattedSignal]

  public static let empty = AccessibilitySnapshot(rows: [])

  public func value(for field: SignalFormatter.Field) -> String? {
    rows.first { $0.id == field }?.value
  }
}

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
  var speechRenderer: SpeechRenderer?
  var feedbackRouter: FeedbackRouter?

  // MARK: - Throttled state (see type-level doc comment)

  public private(set) var visualOutput: EngineOutput?
  public private(set) var accessibilitySnapshot: AccessibilitySnapshot = .empty
  public private(set) var signalStateLine: String = "Not started"

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

  private var lastVisualUpdate: ContinuousClock.Instant = .now
  private var lastAccessibilityUpdate: ContinuousClock.Instant = .now
  private let visualInterval = Duration.milliseconds(100)  // ~10 Hz
  private let accessibilityInterval = Duration.milliseconds(500)  // ~2 Hz

  public init() {
    permissionState = CameraPermissionState(AVCaptureDevice.authorizationStatus(for: .video))

    if let url = try? ConfigStore.defaultURL() {
      let result = ConfigStore.load(from: url)
      config = result.config
      configLoadIssue = result.issue
    } else {
      config = .defaults
      configLoadIssue = nil
    }

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

  // MARK: - Session lifecycle

  public func start() async {
    guard !isRunning else { return }
    guard permissionState == .authorized else {
      captureErrorMessage = "Camera access is not authorized."
      return
    }
    guard let deviceID = selectedCameraID else {
      captureErrorMessage = "No camera selected."
      return
    }

    captureErrorMessage = nil
    // §5's per-mode capture format (Config-keyed, §0/§11 — see
    // `CameraModeCaptureSettings`'s doc comment for why this replaced the
    // former `setupWidth`/`setupHeight`/`setupFrameRate` statics). `start()`
    // always begins in whatever `mode` currently is (`.setup` by default);
    // `setMode(_:)` in `PipelineModel+Mode.swift` is what changes `mode`
    // and restarts capture on an already-running pipeline.
    let modeSettings = config.camera.settings(for: mode)
    let source = CameraCaptureSource(
      deviceUniqueID: deviceID,
      width: modeSettings.width,
      height: modeSettings.height,
      frameRate: modeSettings.frameRate
    )
    let newEngine = AnalysisEngine(backend: VisionBackend(), config: config)

    do {
      try await source.start()
    } catch {
      captureErrorMessage = "Could not start camera: \(error)"
      return
    }

    captureSource = source
    engine = newEngine
    captureFormat = SignalFormatter.CaptureFormatDescriptor(
      width: modeSettings.width, height: modeSettings.height, frameRate: modeSettings.frameRate)
    // Unknown until the first frame actually arrives — see
    // `actualCaptureDimensions`'s doc comment. A fresh session (this is
    // one) must not keep showing a previous session's confirmed dimensions.
    actualCaptureDimensions = nil
    mirrorState = source.mirrorState
    isRunning = true
    signalStateLine = "Starting…"

    // Audio starts with the pipeline (task brief §5.1): same lifecycle as
    // the camera/engine above, degrading to a visible notice rather than
    // failing `start()` if no audio device is available — see
    // `PipelineModel+Audio.swift`.
    await startFeedbackChain()

    beginConsuming(engine: newEngine, source: source, targetAnalysisHz: modeSettings.analysisHz)
  }

  public func stop() async {
    captureGeneration += 1
    consumeTask?.cancel()
    consumeTask = nil
    await captureSource?.stop()
    captureSource = nil
    engine = nil
    // Audio stops with the pipeline (task brief §5.1: "stop → stops
    // cleanly") — see `PipelineModel+Audio.swift`.
    await stopFeedbackChain()
    isRunning = false
    signalStateLine = "Stopped"
    latestOutput = nil
    visualOutput = nil
    accessibilitySnapshot = .empty
  }

  // `beginConsuming(engine:source:targetAnalysisHz:)` — the shared
  // consume-loop spawn used by both `start()` above and `setMode(_:)`'s
  // capture restart — lives in `PipelineModel+Mode.swift`, not here, purely
  // to stay under SwiftLint's file-length limit; see that file for why
  // `captureGeneration` (declared above) is threaded through it.

  // Not `private`: Swift's `private` scopes to the declaring *file*, not
  // the whole type (see `config`'s doc comment above for the same note) —
  // `beginConsuming(engine:source:targetAnalysisHz:)` in
  // `PipelineModel+Mode.swift` calls this from its consume loop, same as
  // `start()` above does.
  func ingest(_ output: EngineOutput) {
    latestOutput = output

    // Latches on the FIRST real frame of the session and never overwrites
    // after that — `actualCaptureDimensions`'s doc comment has the full
    // rationale. Deliberately unthrottled (unlike `visualOutput`/
    // `accessibilitySnapshot` below): the point is to catch the confirmed
    // format as early as possible, not on whatever frame happens to land on
    // a throttle boundary, and after the first non-nil write this is a
    // cheap no-op on every subsequent frame.
    if actualCaptureDimensions == nil, let dimensions = output.capturedPixelDimensions {
      actualCaptureDimensions = dimensions
    }

    let now = ContinuousClock.now
    if now - lastVisualUpdate >= visualInterval {
      lastVisualUpdate = now
      visualOutput = output
      signalStateLine = Self.words(for: output.analysis.signalState)
    }
    if now - lastAccessibilityUpdate >= accessibilityInterval {
      lastAccessibilityUpdate = now
      accessibilitySnapshot = AccessibilitySnapshot(
        rows: SignalFormatter.snapshot(
          output: output,
          backendName: backendDisplayName,
          captureFormat: captureFormat,
          actualCaptureDimensions: actualCaptureDimensions,
          mirrorState: mirrorState,
          display: config.display
        )
      )
    }
  }

  private static func words(for state: SignalState) -> String {
    switch state {
    case .ok: return "OK"
    case .lowConfidence: return "Low confidence"
    case .noFace: return "No face"
    case .noSignal: return "No signal"
    }
  }
}
