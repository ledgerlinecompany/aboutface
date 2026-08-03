import AVFoundation
import CoreMedia
import CoreVideo

/// §12.6's "explicit test/tool that opens the selected device **while
/// another app holds it** and logs the format actually granted. Do not
/// assume the requested format is honored." Backs the `probe-camera` CLI
/// subcommand.
///
/// This tool is what originally found (and now regression-guards) the
/// production bug it was built to catch: `CameraCaptureSource` used to set
/// `device.activeFormat` directly and had that silently reverted by
/// `session.startRunning()` on macOS — see
/// `CameraCaptureSource.configureSession`'s doc comment for the full
/// empirical story. This probe follows the exact same corrected recipe
/// (`CameraSessionPreset` before `startRunning()`, frame durations after)
/// so it measures the app's real configuration path, not a different one.
///
/// Deliberately reports several separate readings rather than one, because
/// each answers a different "was it honored" question:
///
/// 1. `sessionPresetMatched` — whether the requested (width, height) had a
///    known `CameraSessionPreset` mapping that was applied to the session.
///    `false` means this probe fell back to the session's own default
///    preset (`.high`) instead of refusing to run — the resulting mismatch
///    is itself the diagnostic §12.6 wants.
/// 2. `deviceGrantedWidth`/`Height`/`FrameRate` — `AVCaptureDevice
///    .activeFormat`/`activeVideoMinFrameDuration`, read AFTER the session
///    started AND the first frame arrived (not immediately after
///    configuration, which — per the empirical findings above — can claim
///    success and then have `startRunning()` silently revert it). This is
///    genuine post-start truth.
/// 3. `deliveredFrameWidth`/`Height`/`PixelFormat` — read from the actual
///    first `CVPixelBuffer` the session delivers, independent of what the
///    device object claims — the scenario §12.6 exists for is exactly one
///    where these two could still disagree (e.g. concurrent-client format
///    negotiation by another process).
/// 4. `isInUseByAnotherApplication` — read once *before* this probe opens
///    its own session (so it reflects only OTHER processes, not this one).
///
/// ## Concurrency
///
/// Same isolation pattern as `CameraCaptureSource` (see that type's doc
/// comment, and the CLAUDE.md toolchain-skew rule): all AVFoundation
/// objects live inside this actor or the transient delegate/box types below;
/// only the `Sendable` `CameraFormatProbe.Result` crosses out to callers.
public actor CameraFormatProbe {
  public enum ProbeError: Error, Sendable, Equatable {
    case deviceNotFound(String)
    case noDefaultDevice
    case noFormatsAvailable
    case cannotAddInput
    case cannotAddOutput
    case noVideoConnection
    case timedOutWaitingForFrame
  }

  public struct Result: Sendable, Equatable {
    public let deviceUniqueID: String
    public let deviceLocalizedName: String

    public let requestedWidth: Int
    public let requestedHeight: Int
    public let requestedFrameRate: Double

    /// Whether the device reports SOME format matching the request exactly
    /// (width, height, and a frame-rate range containing the requested
    /// rate). Informational only — the matched format is never applied to
    /// the device directly; `sessionPresetMatched`/`session.sessionPreset`
    /// is what actually governs the granted resolution on macOS (see this
    /// type's doc comment).
    public let exactFormatMatchFound: Bool

    /// Whether the requested (width, height) had a known
    /// `CameraSessionPreset` mapping that was applied to
    /// `AVCaptureSession.sessionPreset`. `false` means this probe fell back
    /// to the session's own default preset (`.high`) instead of refusing to
    /// run — check `deviceGrantedWidth`/`Height` for what that actually
    /// produced.
    public let sessionPresetMatched: Bool

    /// `AVCaptureDevice.activeFormat`'s dimensions, read AFTER the session
    /// started and the first frame arrived — post-start truth, not a
    /// pre-start claim (see this type's doc comment for why that ordering
    /// matters on macOS).
    public let deviceGrantedWidth: Int
    public let deviceGrantedHeight: Int
    /// `AVCaptureDevice.activeVideoMinFrameDuration` converted to fps, read
    /// at the same post-start-and-post-first-frame point as
    /// `deviceGrantedWidth`/`Height`.
    public let deviceGrantedFrameRate: Double

    public let deliveredFrameWidth: Int
    public let deliveredFrameHeight: Int
    /// Four-character-code pixel format string (e.g. "BGRA", "420v"), read
    /// from the actually-delivered `CVPixelBuffer`.
    public let deliveredPixelFormat: String

    /// Read BEFORE this probe opened its own session — reflects only other
    /// processes' use of the device, per §12.2/§12.6.
    public let isInUseByAnotherApplication: Bool
  }

  /// - Parameters:
  ///   - deviceUniqueID: `AVCaptureDevice.uniqueID` to probe. `nil` uses
  ///     the system default video device (§12.1's "system default" — same
  ///     convention as `Config.Camera.selectedCameraID == nil`).
  ///   - width/height/frameRate: Requested format, §5.2's Monitor default
  ///     (640×480@15) unless the caller overrides — see `ProbeCameraCommand`.
  ///   - frameTimeoutSeconds: How long to wait for the first delivered
  ///     frame before giving up. Config-keyed by the CLI caller, not
  ///     hardcoded here (§0) — this type just takes the value.
  public static func probe(
    deviceUniqueID: String?,
    width: Int,
    height: Int,
    frameRate: Double,
    frameTimeoutSeconds: Double
  ) async throws -> Result {
    let device = try resolveDevice(uniqueID: deviceUniqueID)
    // Read BEFORE we touch the session ourselves, per the type-level doc
    // comment.
    let busyBeforeOpen = device.isInUseByAnotherApplication

    let exactMatch = try hasExactFormatMatch(
      device: device, width: width, height: height, frameRate: frameRate)

    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true

    session.beginConfiguration()

    // `session.sessionPreset`, not `device.activeFormat`, is what actually
    // governs the granted resolution on macOS — see this type's doc
    // comment and `CameraCaptureSource.configureSession`'s for the full
    // empirical story (found via this very tool). Unlike
    // `CameraCaptureSource`, an unmapped size is not fatal here: this
    // probe's whole job is to surface exactly this kind of mismatch, so it
    // falls back to the session's own default preset (`.high`) and lets
    // `Result.sessionPresetMatched == false` carry that fact through to the
    // report instead of refusing to run.
    let mappedPreset = CameraSessionPreset.preset(forWidth: width, height: height)
    let sessionPresetMatched: Bool
    if let mappedPreset, session.canSetSessionPreset(mappedPreset) {
      session.sessionPreset = mappedPreset
      sessionPresetMatched = true
    } else {
      sessionPresetMatched = false
    }

    guard session.canAddInput(input) else { throw ProbeError.cannotAddInput }
    session.addInput(input)
    guard session.canAddOutput(output) else { throw ProbeError.cannotAddOutput }
    session.addOutput(output)
    guard output.connection(with: .video) != nil else { throw ProbeError.noVideoConnection }

    // Must be committed BEFORE `captureOneFrame` calls `startRunning()` —
    // unlike `commitConfiguration`'s own timing, `startRunning()` is the
    // one ordering boundary that genuinely matters (see the comment above).
    session.commitConfiguration()

    let queue = DispatchQueue(label: "com.ledgerlinecompany.aboutface.probe-camera")
    let captureRequest = CaptureRequest(
      session: session, output: output, device: device, requestedFrameRate: frameRate,
      timeoutSeconds: frameTimeoutSeconds)
    let outcome = try await Self.captureOneFrame(captureRequest, queue: queue)

    return Result(
      deviceUniqueID: device.uniqueID,
      deviceLocalizedName: device.localizedName,
      requestedWidth: width,
      requestedHeight: height,
      requestedFrameRate: frameRate,
      exactFormatMatchFound: exactMatch,
      sessionPresetMatched: sessionPresetMatched,
      deviceGrantedWidth: outcome.deviceGrantedWidth,
      deviceGrantedHeight: outcome.deviceGrantedHeight,
      deviceGrantedFrameRate: outcome.deviceGrantedFrameRate,
      deliveredFrameWidth: outcome.deliveredWidth,
      deliveredFrameHeight: outcome.deliveredHeight,
      deliveredPixelFormat: outcome.deliveredPixelFormat,
      isInUseByAnotherApplication: busyBeforeOpen
    )
  }

  private static func resolveDevice(uniqueID: String?) throws -> AVCaptureDevice {
    guard let uniqueID else {
      guard let device = AVCaptureDevice.default(for: .video) else {
        throw ProbeError.noDefaultDevice
      }
      return device
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: AVCaptureDeviceProvider.defaultDeviceTypes,
      mediaType: .video,
      position: .unspecified
    )
    guard let device = discovery.devices.first(where: { $0.uniqueID == uniqueID }) else {
      throw ProbeError.deviceNotFound(uniqueID)
    }
    return device
  }

  /// Whether the device reports SOME format matching the request exactly.
  /// Informational only now — see this type's doc comment for why the
  /// matched format is never applied to the device directly;
  /// `session.sessionPreset` (set in `probe(...)`) is what actually governs
  /// the granted resolution on macOS.
  private static func hasExactFormatMatch(
    device: AVCaptureDevice, width: Int, height: Int, frameRate: Double
  ) throws -> Bool {
    guard !device.formats.isEmpty else { throw ProbeError.noFormatsAvailable }
    return device.formats.contains { format in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard Int(dims.width) == width, Int(dims.height) == height else { return false }
      return format.videoSupportedFrameRateRanges.contains {
        frameRate >= $0.minFrameRate && frameRate <= $0.maxFrameRate
      }
    }
  }

  private static func actualFrameRate(device: AVCaptureDevice) -> Double {
    let duration = device.activeVideoMinFrameDuration
    guard duration.timescale != 0, duration.value != 0 else { return 0 }
    return Double(duration.timescale) / Double(duration.value)
  }

  // Not `fileprivate`/`private`: constructed from `ProbeFrameDelegate` in
  // `CameraFormatProbeSupport.swift` (a separate file, split out purely to
  // stay under SwiftLint's `file_length` limit), so this needs at least
  // `internal` (the implicit default) visibility.
  struct DeliveredFrame: Sendable {
    let width: Int
    let height: Int
    let pixelFormat: String
  }

  /// What `captureOneFrame` measures: the actually-delivered frame's pixel
  /// data, plus the device's own post-start/post-frame `activeFormat`
  /// reading — both read at the same point in time, right before the
  /// session stops.
  fileprivate struct CaptureOutcome: Sendable {
    let deliveredWidth: Int
    let deliveredHeight: Int
    let deliveredPixelFormat: String
    let deviceGrantedWidth: Int
    let deviceGrantedHeight: Int
    let deviceGrantedFrameRate: Double
  }

  /// Bundles `captureOneFrame`'s inputs — purely to keep that function's
  /// parameter count under SwiftLint's limit; not otherwise meaningful as
  /// a standalone value.
  private struct CaptureRequest {
    let session: AVCaptureSession
    let output: AVCaptureVideoDataOutput
    let device: AVCaptureDevice
    let requestedFrameRate: Double
    let timeoutSeconds: Double
  }

  /// Starts `request.session`, waits for exactly one delivered sample
  /// buffer (or `request.timeoutSeconds`), reads the device's granted
  /// format, then stops the session. Mirrors `CameraCaptureSource.start()`'s
  /// captureQueue-dispatched `startRunning()` pattern — blocking
  /// AVFoundation calls never touch the actor's own executor or the
  /// caller's task directly.
  ///
  /// Frame durations are set AFTER `startRunning()`, and the granted
  /// format is read AFTER the first frame arrives and BEFORE
  /// `stopRunning()` — see `probe(...)`'s doc comment for why both of
  /// those orderings matter on macOS.
  private static func captureOneFrame(
    _ request: CaptureRequest,
    queue: DispatchQueue
  ) async throws -> CaptureOutcome {
    let sessionBox = ProbeSessionBox(request.session)
    let deviceBox = ProbeDeviceBox(request.device)
    let output = request.output
    let requestedFrameRate = request.requestedFrameRate

    let frame: DeliveredFrame? = await withCheckedContinuation { continuation in
      let delegate = ProbeFrameDelegate(continuation: continuation)
      output.setSampleBufferDelegate(delegate, queue: queue)
      queue.async {
        sessionBox.session.startRunning()

        // Best-effort: like `CameraCaptureSource.start()`, frame durations
        // only stick if set AFTER `startRunning()`. A failure here still
        // lets the probe report whatever `activeVideoMinFrameDuration` the
        // granted preset defaults to, which is itself useful diagnostic
        // information — not worth aborting the probe over.
        do {
          try deviceBox.device.lockForConfiguration()
          let duration = CMTime(value: 1, timescale: CMTimeScale(requestedFrameRate))
          deviceBox.device.activeVideoMinFrameDuration = duration
          deviceBox.device.activeVideoMaxFrameDuration = duration
          deviceBox.device.unlockForConfiguration()
        } catch {
          // Best effort — see comment above.
        }
      }
      queue.asyncAfter(deadline: .now() + request.timeoutSeconds) {
        delegate.timeOut()
      }
    }

    guard let frame else { throw ProbeError.timedOutWaitingForFrame }

    // Read the granted format AFTER the first frame has actually arrived
    // and BEFORE stopping the session — post-start-and-post-frame truth,
    // not a pre-start claim `startRunning()` might still revert.
    return await withCheckedContinuation { resume in
      queue.async {
        let dims = CMVideoFormatDescriptionGetDimensions(
          deviceBox.device.activeFormat.formatDescription)
        let grantedFrameRate = Self.actualFrameRate(device: deviceBox.device)
        if sessionBox.session.isRunning {
          sessionBox.session.stopRunning()
        }
        resume.resume(
          returning: CaptureOutcome(
            deliveredWidth: frame.width,
            deliveredHeight: frame.height,
            deliveredPixelFormat: frame.pixelFormat,
            deviceGrantedWidth: Int(dims.width),
            deviceGrantedHeight: Int(dims.height),
            deviceGrantedFrameRate: grantedFrameRate
          ))
      }
    }
  }
}

// `ProbeSessionBox`, `ProbeDeviceBox`, `ProbeFrameDelegate`, and
// `PixelFormatCode` are defined in `CameraFormatProbeSupport.swift`, not
// inline here — split purely to stay under SwiftLint's `file_length` limit.
