// swift-format and swiftlint disagree on case-sensitive vs. case-insensitive
// import ordering (see Sources/AboutFaceCore/Capture/FileCaptureSource.swift
// for the canonical example of this same conflict); this order satisfies
// `swift format lint`, which the CI gate also enforces.
// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore
import AppKit
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
/// Split across three files purely to stay under SwiftLint's file-length
/// limit, the same reasoning `AnalysisEngine`'s `+Framing`/`+Geometry` file
/// split uses — everywhere below is still `PipelineModel`'s own
/// implementation, not a separate public surface:
/// - `PipelineModel.swift` (this file): stored state, `init`, camera
///   permission, and the capture/engine session lifecycle.
/// - `PipelineModel+Config.swift`: `Config` load/save/reset/export/import
///   and the slider `Binding` helpers (§9/§11).
/// - `PipelineModel+Target.swift`: "capture current position as target"
///   (§4).
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
  public private(set) var permissionState: CameraPermissionState

  // MARK: - Config (§11)

  // `internal(set)`, not `private(set)`: written from `updateConfig(_:)` in
  // `PipelineModel+Config.swift` — `private` in Swift scopes to the
  // declaring *file*, not the whole type, so a setter used from another
  // extension file needs at least `internal` visibility.
  public internal(set) var config: Config
  public private(set) var configLoadIssue: ConfigStore.LoadIssue?

  // MARK: - Session lifecycle

  public private(set) var isRunning = false
  public private(set) var captureErrorMessage: String?

  // MARK: - Throttled state (see type-level doc comment)

  public private(set) var visualOutput: EngineOutput?
  public private(set) var accessibilitySnapshot: AccessibilitySnapshot = .empty
  public private(set) var signalStateLine: String = "Not started"

  // MARK: - Static-per-session context fed to `SignalFormatter`

  public private(set) var captureFormat: SignalFormatter.CaptureFormatDescriptor?
  public private(set) var mirrorState: MirrorState?
  public let backendDisplayName = VisionBackend.displayName

  // MARK: - Private engine/session state

  var captureSource: CameraCaptureSource?
  var engine: AnalysisEngine?
  var consumeTask: Task<Void, Never>?
  var saveTask: Task<Void, Never>?

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

  // Setup mode's capture format (§5.1): "Capture format 1280×720 @ 30fps."
  // Kept as constants here, matching `CameraCaptureSource`'s own defaults —
  // its doc comment explains why these are init parameters rather than
  // `Config` fields for now (Setup vs. Monitor mode want different values
  // and mode-specific wiring hasn't landed).
  private static let setupWidth = 1280
  private static let setupHeight = 720
  private static let setupFrameRate = 30.0

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

    if selectedCameraID == nil {
      selectedCameraID = cameraDiscovery.devices.first?.id
    }
  }

  // MARK: - Camera permission (§9/§12)

  /// Requests camera access if not already determined. No-op otherwise —
  /// once the user has answered, only System Settings can change it, which
  /// is what `openSystemSettingsForCameraPrivacy()` is for.
  public func requestCameraPermission() async {
    guard permissionState == .notDetermined else { return }
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .video) { granted in
        continuation.resume(returning: granted)
      }
    }
    permissionState = granted ? .authorized : .denied
  }

  /// Deep-links to the Camera privacy pane so a denied user can fix it
  /// without hunting through System Settings (spec §9's permission-flow
  /// requirement: "show a clear message + System Settings link when
  /// denied").
  public func openSystemSettingsForCameraPrivacy() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

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
    let source = CameraCaptureSource(
      deviceUniqueID: deviceID,
      width: Self.setupWidth,
      height: Self.setupHeight,
      frameRate: Self.setupFrameRate
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
      width: Self.setupWidth, height: Self.setupHeight, frameRate: Self.setupFrameRate)
    mirrorState = source.mirrorState
    isRunning = true
    signalStateLine = "Starting…"

    consumeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        for try await item in newEngine.stream(from: source) {
          self.ingest(item)
        }
      } catch {
        self.captureErrorMessage = "Capture stopped: \(error)"
      }
      self.isRunning = false
    }
  }

  public func stop() async {
    consumeTask?.cancel()
    consumeTask = nil
    await captureSource?.stop()
    captureSource = nil
    engine = nil
    isRunning = false
    signalStateLine = "Stopped"
    latestOutput = nil
    visualOutput = nil
    accessibilitySnapshot = .empty
  }

  private func ingest(_ output: EngineOutput) {
    latestOutput = output

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
          mirrorState: mirrorState
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
