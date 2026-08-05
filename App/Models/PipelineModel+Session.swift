// swift-format and swiftlint disagree on case-sensitive vs. case-insensitive
// import ordering (see PipelineModel.swift for the same conflict); this
// order satisfies `swift format lint`, which the CI gate also enforces.
// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore
import Foundation

// swiftlint:enable sorted_imports

/// `PipelineModel`'s capture/engine session lifecycle — `start()` and
/// `stop()`. Split out of `PipelineModel.swift` purely to keep that file
/// under SwiftLint's `file_length` limit with headroom, same precedent as
/// `PipelineModel+Mode.swift`/`+Target.swift`/`+Config.swift`/`+Camera.swift`
/// /`+Ingest.swift`; everything here is still `PipelineModel`'s own
/// implementation, not a separate public surface.
extension PipelineModel {
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
}
