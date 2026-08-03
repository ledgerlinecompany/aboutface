import AVFoundation
import CoreMedia
import CoreVideo

/// A `CaptureSource` backed by a live `AVCaptureSession` — the `camera` half
/// of spec §3.1's `(camera|file)` abstraction.
///
/// ## Concurrency (§3.1)
///
/// Sample buffers are delivered on a dedicated, high-priority serial
/// `DispatchQueue` (`captureQueue`) — never the actor's own executor, and
/// never the main queue — via `AVCaptureVideoDataOutputSampleBufferDelegate`.
/// The delegate callback does the minimum possible work (wrap the sample
/// buffer's image buffer in a `CapturedFrame` and yield it to the stream's
/// continuation) and never hops onto the actor or awaits anything, so it can
/// never be blocked by a slow analysis consumer. `AVCaptureSession.startRunning()`
/// / `stopRunning()` are blocking calls; they are dispatched onto
/// `captureQueue` as well, off of both the actor's executor and the caller's
/// task, so `start()`/`stop()` remain safely awaitable without blocking a
/// cooperative-pool thread.
///
/// ## Mirror state (§3.4)
///
/// `connection.isVideoMirrored` is set **explicitly**, to `false`, at session
/// configuration time — never left at the platform default, which varies by
/// device and OS version. `automaticallyAdjustsVideoMirroring` is disabled
/// first, since `isVideoMirrored` is only settable once automatic adjustment
/// is off. This source always delivers the raw, unmirrored sensor image and
/// stamps every frame `.notMirrored` to match; there is currently no
/// supported way to request a mirrored live capture (nothing in the pipeline
/// needs one — see `FileCaptureSource` for why the mirrored acceptance test
/// uses corpus replay instead).
public actor CameraCaptureSource: CaptureSource {
  /// Coarse session lifecycle, surfaced instead of throwing/crashing on
  /// interruption or runtime error (§3.1: capture must never block or
  /// fatalError; failures are observable state, not thrown exceptions,
  /// since they can happen asynchronously at any time after `start()`
  /// returns).
  public enum State: Sendable, Equatable {
    case idle
    case running
    /// The system interrupted the session (e.g. another app took the
    /// camera, or a Continuity Camera device disconnected). `reason`
    /// is `AVCaptureSession.InterruptionReason`'s debug description.
    case interrupted(reason: String)
    case stopped
    /// An unrecoverable runtime error occurred; `frames` has finished.
    case failed(String)
  }

  public nonisolated let mirrorState: MirrorState = .notMirrored
  public nonisolated let frames: AsyncStream<CapturedFrame>

  private let continuation: AsyncStream<CapturedFrame>.Continuation
  private let deviceUniqueID: String
  private let width: Int
  private let height: Int
  private let frameRate: Double

  private let session = AVCaptureSession()
  private let captureQueue = DispatchQueue(
    label: "com.ledgerlinecompany.aboutface.capture",
    qos: .userInteractive
  )

  private var delegate: CameraSampleBufferDelegate?
  private var runtimeErrorObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var interruptionEndedObserver: NSObjectProtocol?

  /// The device `configureSession()` resolved and attached to `session`,
  /// stashed so `start()` can reach it to set frame durations AFTER
  /// `startRunning()` — see `configureSession`'s doc comment for why that
  /// ordering is required. Resolved fresh every `start()` call (not cached
  /// across restarts), consistent with `deviceUniqueID`'s own "resolved at
  /// `start()` time, not cached at `init`" contract.
  private var resolvedDevice: AVCaptureDevice?

  public private(set) var state: State = .idle

  /// - Parameters:
  ///   - deviceUniqueID: `AVCaptureDevice.uniqueID` of the camera to open.
  ///     Resolved from the observed device list at `start()` time, not
  ///     cached at `init` — per §12.1, camera identity should come from an
  ///     observed `AVCaptureDevice.DiscoverySession`, not a launch-time
  ///     snapshot, since Continuity Camera devices come and go. Higher-level
  ///     device *selection* (enumeration UI, "which camera is this") is out
  ///     of scope for this type; it only resolves an already-chosen ID.
  ///   - width: Requested frame width in pixels. §5.1 default: 1280.
  ///   - height: Requested frame height in pixels. §5.1 default: 720.
  ///   - frameRate: Requested capture frame rate in fps. §5.1 default: 30.
  ///
  /// Format is requested **explicitly** at these exact values (§5.1/§5.2:
  /// "requested explicitly, not negotiated") — deliberately kept as `init`
  /// parameters rather than `Config` fields for now, since Setup (1280×720@30)
  /// and Monitor (640×480@15) modes want different values and mode-specific
  /// wiring hasn't landed yet.
  public init(
    deviceUniqueID: String,
    width: Int = 1280,
    height: Int = 720,
    frameRate: Double = 30
  ) {
    self.deviceUniqueID = deviceUniqueID
    self.width = width
    self.height = height
    self.frameRate = frameRate

    let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.frames = stream
    self.continuation = continuation
  }

  public func start() async throws {
    guard state != .running else { return }

    try configureSession()
    observeSessionNotifications()

    // `resolvedDevice` is always set by `configureSession()` before it
    // returns without throwing; this guard exists only so `start()` never
    // force-unwraps, not because this branch is expected to be reachable.
    guard let device = resolvedDevice else {
      throw CameraCaptureSourceError.deviceNotFound(deviceUniqueID)
    }

    let sessionBox = CameraSessionBox(session)
    let deviceBox = CameraDeviceBox(device)
    let requestedFrameRate = frameRate

    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      captureQueue.async {
        sessionBox.session.startRunning()

        // Frame durations, unlike `sessionPreset` (set in
        // `configureSession()`, before `startRunning()`), only stick if set
        // AFTER `startRunning()` — see `configureSession`'s doc comment for
        // the full empirical story (found via `probe-camera`, §12.6).
        // Best-effort: a failure here (e.g. the device vanished between
        // `configureSession()` and now) leaves capture running at whatever
        // rate the granted preset defaults to — a working, if untuned,
        // session — which is not worth failing `start()` over.
        do {
          try deviceBox.device.lockForConfiguration()
          let frameDuration = CMTime(value: 1, timescale: CMTimeScale(requestedFrameRate))
          deviceBox.device.activeVideoMinFrameDuration = frameDuration
          deviceBox.device.activeVideoMaxFrameDuration = frameDuration
          deviceBox.device.unlockForConfiguration()
        } catch {
          // Best effort — see comment above.
        }

        resume.resume()
      }
    }
    state = .running
  }

  public func stop() async {
    removeSessionNotifications()

    let box = CameraSessionBox(session)
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      captureQueue.async {
        if box.session.isRunning {
          box.session.stopRunning()
        }
        resume.resume()
      }
    }
    continuation.finish()
    state = .stopped
  }

  /// - Note on format ordering (found via `probe-camera`, §12.6 — the
  ///   exact class of silent format disagreement that tool exists to
  ///   catch): earlier revisions of this method set
  ///   `device.activeFormat` directly, on the theory (from the
  ///   `AVCaptureSessionPreset` header) that setting the active format on
  ///   an attached device switches the session to input-priority
  ///   behavior. Empirically, on macOS, that switch does **not** happen —
  ///   `.inputPriority` itself is `API_UNAVAILABLE` on macOS, and
  ///   `session.startRunning()` silently reverts `activeFormat` back to
  ///   whatever `sessionPreset` implies (`.high` → 1920×1080), regardless
  ///   of when `activeFormat` was set relative to `addInput`/
  ///   `commitConfiguration`. This was masked until now because Setup's
  ///   1280×720 request happens to equal `.high`'s native resolution on
  ///   the reference hardware (the "29.6fps" Phase 1 acceptance numbers
  ///   were `.high`'s native ~30fps, coincidentally close to the
  ///   requested rate) — but Monitor's §5.2 explicit 640×480@15 (the
  ///   CPU/thermal requirement: "requested explicitly, not negotiated")
  ///   was silently NOT honored. What actually works: set
  ///   `session.sessionPreset` (below, inside `beginConfiguration`) —
  ///   this DOES stick through `startRunning()` — and set the frame-rate
  ///   duration fields separately, AFTER `startRunning()` (`start()`
  ///   does this; setting them before `startRunning()`, even alongside a
  ///   correct preset, gets silently reverted to the preset's native
  ///   rate the same way `activeFormat` did).
  private func configureSession() throws {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
      mediaType: .video,
      position: .unspecified
    )
    guard let device = discovery.devices.first(where: { $0.uniqueID == deviceUniqueID }) else {
      throw CameraCaptureSourceError.deviceNotFound(deviceUniqueID)
    }

    let input = try AVCaptureDeviceInput(device: device)

    // Validation only, for a clear error message up front — confirms the
    // device actually has SOME format matching the requested (width,
    // height, frameRate). The matched `AVCaptureDevice.Format` value
    // itself is deliberately never applied (`device.activeFormat = ...`);
    // see this method's doc comment for why that is empirically futile on
    // macOS. `session.sessionPreset`, set below, is what actually governs
    // the granted resolution.
    guard
      Self.matchingFormat(device: device, width: width, height: height, frameRate: frameRate)
        != nil
    else {
      throw CameraCaptureSourceError.unsupportedFormat(
        width: width, height: height, frameRate: frameRate
      )
    }

    guard let preset = CameraSessionPreset.preset(forWidth: width, height: height) else {
      throw CameraCaptureSourceError.unsupportedFormat(
        width: width, height: height, frameRate: frameRate
      )
    }

    let output = AVCaptureVideoDataOutput()
    // `kCVPixelBufferWidthKey`/`HeightKey` are what ACTUALLY govern the
    // dimensions of the buffers this output delivers on macOS. Neither
    // `device.activeFormat` (reverted by `startRunning()` — PR #53) nor
    // `session.sessionPreset` (set below, and genuinely applied) controls
    // them: measured on the reference hardware, a session with
    // `.hd1280x720` and a request for 1280×720 delivered 1920×1080 buffers,
    // and a request for 640×480 with `.vga640x480` did the same. Adding
    // these two keys — and changing nothing else — produced exactly the
    // requested dimensions in both cases.
    //
    // This mattered for a long time without being visible. PR #53 fixed the
    // FRAME RATE half of the same family of bug (durations applied after
    // `startRunning()`) and concluded the preset governed resolution; the
    // resolution was never read back, and `SignalFormatter` reported the
    // REQUESTED dimensions, so every surface in the app confidently echoed
    // the number we had asked for. Setup ran at 1080p while reporting 720p
    // for the whole of Phases 2–4. The only symptom was dropped frames at
    // 30fps, which reads as a performance problem rather than a format one.
    //
    // Disproved on the way to this, recorded so nobody retries it: applying
    // `sessionPreset` AFTER `addInput` rather than before (on the theory
    // that adding an input re-evaluates the preset) changes nothing —
    // still 1920×1080. The preset ordering below is therefore the original
    // ordering, deliberately left alone.
    //
    // Verified with `aboutface-cli live`'s actual-vs-requested readout
    // (`CapturedFrame.pixelDimensions`), which is the only reason any of
    // this was observable. Do not remove that readout.
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's trailing_comma rule forbids
    // one. Same tool disagreement noted elsewhere in this codebase — format
    // wins.
    // swiftlint:disable trailing_comma
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    // swiftlint:enable trailing_comma
    output.alwaysDiscardsLateVideoFrames = true

    let delegate = CameraSampleBufferDelegate(continuation: continuation, mirrorState: mirrorState)
    output.setSampleBufferDelegate(delegate, queue: captureQueue)
    self.delegate = delegate

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    guard session.canSetSessionPreset(preset) else {
      throw CameraCaptureSourceError.unsupportedFormat(
        width: width, height: height, frameRate: frameRate
      )
    }
    session.sessionPreset = preset

    guard session.canAddInput(input) else { throw CameraCaptureSourceError.cannotAddInput }
    session.addInput(input)

    guard session.canAddOutput(output) else { throw CameraCaptureSourceError.cannotAddOutput }
    session.addOutput(output)

    guard let connection = output.connection(with: .video) else {
      throw CameraCaptureSourceError.noVideoConnection
    }

    // §3.4: mirror convention MUST be set explicitly at session
    // configuration, never inherited from the platform default (it varies
    // by device and OS version). `automaticallyAdjustsVideoMirroring` must
    // be disabled first — `isVideoMirrored` is not settable while it's on.
    connection.automaticallyAdjustsVideoMirroring = false
    connection.isVideoMirrored = false

    resolvedDevice = device
  }

  private func observeSessionNotifications() {
    let center = NotificationCenter.default
    runtimeErrorObserver = center.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification,
      object: session,
      queue: nil
    ) { [weak self] notification in
      let message =
        (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
        ?? "unknown capture session runtime error"
      Task { await self?.handleRuntimeError(message) }
    }
    // Note: `AVCaptureSessionInterruptionReasonKey` / `AVCaptureSession.InterruptionReason`
    // are unavailable on macOS (iOS/tvOS-only API), so unlike those platforms
    // we cannot report *why* the session was interrupted here — only that it
    // was. `state` still surfaces the fact of the interruption, per the
    // requirement that failures be observable rather than silent.
    interruptionObserver = center.addObserver(
      forName: AVCaptureSession.wasInterruptedNotification,
      object: session,
      queue: nil
    ) { [weak self] _ in
      Task { await self?.handleInterruption("session interrupted") }
    }
    interruptionEndedObserver = center.addObserver(
      forName: AVCaptureSession.interruptionEndedNotification,
      object: session,
      queue: nil
    ) { [weak self] _ in
      Task { await self?.handleInterruptionEnded() }
    }
  }

  private func removeSessionNotifications() {
    let center = NotificationCenter.default
    for token in [runtimeErrorObserver, interruptionObserver, interruptionEndedObserver] {
      if let token {
        center.removeObserver(token)
      }
    }
    runtimeErrorObserver = nil
    interruptionObserver = nil
    interruptionEndedObserver = nil
  }

  private func handleRuntimeError(_ message: String) {
    state = .failed(message)
    continuation.finish()
  }

  private func handleInterruption(_ reason: String) {
    state = .interrupted(reason: reason)
  }

  private func handleInterruptionEnded() {
    guard case .interrupted = state else { return }
    state = .running
  }
}

public enum CameraCaptureSourceError: Error, Sendable, Equatable {
  case deviceNotFound(String)
  case unsupportedFormat(width: Int, height: Int, frameRate: Double)
  case cannotAddInput
  case cannotAddOutput
  case noVideoConnection
}

// `CameraSessionBox`, `CameraDeviceBox`, `CameraSampleBufferDelegate`, and its `Sendable`
// extension are defined in `CameraCaptureSourceSupport.swift`, not inline
// here — split purely to stay under SwiftLint's `file_length` limit.
