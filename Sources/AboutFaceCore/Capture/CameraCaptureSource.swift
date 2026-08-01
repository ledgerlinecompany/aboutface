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

  private var delegate: SampleBufferDelegate?
  private var runtimeErrorObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var interruptionEndedObserver: NSObjectProtocol?

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

  /// Convenience for opening the system default video device, per §12.1's
  /// note that explicit user selection (stored per profile) is the normal
  /// path — this exists only for tests/tools/harnesses that don't have a
  /// profile to read a stored `uniqueID` from. Returns `nil` if there is no
  /// default video device (e.g. headless CI).
  public static func defaultDevice(
    width: Int = 1280,
    height: Int = 720,
    frameRate: Double = 30
  ) -> CameraCaptureSource? {
    guard let device = AVCaptureDevice.default(for: .video) else { return nil }
    return CameraCaptureSource(
      deviceUniqueID: device.uniqueID,
      width: width,
      height: height,
      frameRate: frameRate
    )
  }

  public func start() async throws {
    guard state != .running else { return }

    try configureSession()
    observeSessionNotifications()

    let box = SessionBox(session)
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      captureQueue.async {
        box.session.startRunning()
        resume.resume()
      }
    }
    state = .running
  }

  public func stop() async {
    removeSessionNotifications()

    let box = SessionBox(session)
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

    guard
      let format = Self.matchingFormat(
        device: device, width: width, height: height, frameRate: frameRate
      )
    else {
      throw CameraCaptureSourceError.unsupportedFormat(
        width: width, height: height, frameRate: frameRate
      )
    }

    try device.lockForConfiguration()
    device.activeFormat = format
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration
    device.unlockForConfiguration()

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true

    let delegate = SampleBufferDelegate(continuation: continuation, mirrorState: mirrorState)
    output.setSampleBufferDelegate(delegate, queue: captureQueue)
    self.delegate = delegate

    session.beginConfiguration()
    defer { session.commitConfiguration() }

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
  }

  private static func matchingFormat(
    device: AVCaptureDevice,
    width: Int,
    height: Int,
    frameRate: Double
  ) -> AVCaptureDevice.Format? {
    device.formats.first { format in
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard Int(dimensions.width) == width, Int(dimensions.height) == height else { return false }
      return format.videoSupportedFrameRateRanges.contains { range in
        frameRate >= range.minFrameRate && frameRate <= range.maxFrameRate
      }
    }
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

/// A `Sendable` wrapper around the actor-owned `AVCaptureSession`, used only
/// to move the session across the `captureQueue.async` boundary in
/// `start()`/`stop()`. `AVCaptureSession` predates Swift concurrency and
/// isn't `Sendable`-annotated, but the session is designed to have its
/// blocking `startRunning()`/`stopRunning()` calls invoked from a queue
/// other than the one that configured it; `@unchecked Sendable` here
/// reflects that documented Apple usage pattern (dedicated-queue lifecycle
/// calls), not a bypass of an actual data race.
private final class SessionBox: @unchecked Sendable {
  let session: AVCaptureSession

  init(_ session: AVCaptureSession) {
    self.session = session
  }
}

/// Forwards sample buffers from `AVCaptureVideoDataOutput`'s delegate
/// callback directly into the source's `AsyncStream.Continuation`.
///
/// This is a plain `NSObject` (Objective-C delegate protocols require a
/// class) rather than the actor itself, deliberately: it runs on
/// `captureQueue`, not the actor's executor, and must never hop across
/// isolation domains to deliver a frame — that hop is exactly the kind of
/// blocking risk §3.1 rules out for the capture queue. Its only state is two
/// `let` bindings, both themselves `Sendable` (`AsyncStream.Continuation` is
/// unconditionally `Sendable`; `MirrorState` is a plain `Sendable` enum), so
/// `@unchecked Sendable` reflects a genuinely immutable, thread-safe value
/// rather than papering over shared mutable state.
private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let continuation: AsyncStream<CapturedFrame>.Continuation
  private let mirrorState: MirrorState

  init(continuation: AsyncStream<CapturedFrame>.Continuation, mirrorState: MirrorState) {
    self.continuation = continuation
    self.mirrorState = mirrorState
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let frame = CapturedFrame(
      pixelBuffer: pixelBuffer, timestamp: timestamp, mirrorState: mirrorState)
    continuation.yield(frame)
  }
}

// See the type-level documentation above for why `@unchecked Sendable` is safe here.
// Declared via a retroactive extension (rather than inline on the class) purely so the
// primary declaration line stays short enough that swiftlint's `opening_brace` rule (brace
// on the same line) and swift-format's line-length-driven wrapping don't fight each other.
extension SampleBufferDelegate: @unchecked Sendable {}
