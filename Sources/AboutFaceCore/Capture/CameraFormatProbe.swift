import AVFoundation
import CoreMedia
import CoreVideo

/// §12.6's "explicit test/tool that opens the selected device **while
/// another app holds it** and logs the format actually granted. Do not
/// assume the requested format is honored." Backs the `probe-camera` CLI
/// subcommand.
///
/// Deliberately reports THREE separate readings rather than one, because
/// each answers a different "was it honored" question:
///
/// 1. `deviceGrantedFormat`/`deviceGrantedFrameRate` — what
///    `AVCaptureDevice.activeFormat` reports immediately after this probe
///    configures the session. This is "what we successfully told the
///    device to become," which can silently differ from the request if no
///    exact match existed and this probe fell back to the nearest
///    available format (see `matchingFormat`/`nearestFormat`).
/// 2. `deliveredFrameWidth`/`Height`/`PixelFormat` — read from the actual
///    first `CVPixelBuffer` the session delivers. This is ground truth for
///    what streamed, independent of what the device object claims — the
///    scenario §12.6 exists for is exactly one where these two could
///    disagree (concurrent-client format negotiation).
/// 3. `isInUseByAnotherApplication` — read once *before* this probe opens
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

    /// `false` if no exact (width, height, frame-rate-in-range) format
    /// existed and this probe used the nearest available format instead.
    public let exactFormatMatchFound: Bool

    public let deviceGrantedWidth: Int
    public let deviceGrantedHeight: Int
    /// `AVCaptureDevice.activeVideoMinFrameDuration` converted to fps —
    /// what the device object reports it will deliver at most.
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

    let (format, exactMatch) = try selectFormat(
      device: device, width: width, height: height, frameRate: frameRate)

    try device.lockForConfiguration()
    device.activeFormat = format
    let clampedRate = Self.clampFrameRate(frameRate, to: format)
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedRate))
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration
    device.unlockForConfiguration()

    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let grantedFrameRate = Self.actualFrameRate(device: device)

    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true

    session.beginConfiguration()
    guard session.canAddInput(input) else { throw ProbeError.cannotAddInput }
    session.addInput(input)
    guard session.canAddOutput(output) else { throw ProbeError.cannotAddOutput }
    session.addOutput(output)
    guard output.connection(with: .video) != nil else { throw ProbeError.noVideoConnection }
    session.commitConfiguration()

    let queue = DispatchQueue(label: "com.ledgerlinecompany.aboutface.probe-camera")
    let delivered = try await Self.captureOneFrame(
      session: session, output: output, queue: queue, timeoutSeconds: frameTimeoutSeconds)

    return Result(
      deviceUniqueID: device.uniqueID,
      deviceLocalizedName: device.localizedName,
      requestedWidth: width,
      requestedHeight: height,
      requestedFrameRate: frameRate,
      exactFormatMatchFound: exactMatch,
      deviceGrantedWidth: Int(dimensions.width),
      deviceGrantedHeight: Int(dimensions.height),
      deviceGrantedFrameRate: grantedFrameRate,
      deliveredFrameWidth: delivered.width,
      deliveredFrameHeight: delivered.height,
      deliveredPixelFormat: delivered.pixelFormat,
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

  /// Exact match first (same logic as `CameraCaptureSource.matchingFormat`);
  /// falls back to the format whose dimensions are closest by pixel area,
  /// so the probe can still run and report a mismatch instead of just
  /// failing — the mismatch itself is diagnostic information §12.6 wants.
  private static func selectFormat(
    device: AVCaptureDevice, width: Int, height: Int, frameRate: Double
  ) throws -> (format: AVCaptureDevice.Format, exactMatch: Bool) {
    guard !device.formats.isEmpty else { throw ProbeError.noFormatsAvailable }

    if let exact = device.formats.first(where: { format in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard Int(dims.width) == width, Int(dims.height) == height else { return false }
      return format.videoSupportedFrameRateRanges.contains {
        frameRate >= $0.minFrameRate && frameRate <= $0.maxFrameRate
      }
    }) {
      return (exact, true)
    }

    let targetArea = width * height
    let nearest = device.formats.min { lhs, rhs in
      let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
      let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
      let lhsDelta = abs(Int(lhsDims.width) * Int(lhsDims.height) - targetArea)
      let rhsDelta = abs(Int(rhsDims.width) * Int(rhsDims.height) - targetArea)
      return lhsDelta < rhsDelta
    }
    guard let nearest else { throw ProbeError.noFormatsAvailable }
    return (nearest, false)
  }

  private static func clampFrameRate(
    _ requested: Double, to format: AVCaptureDevice.Format
  ) -> Double {
    guard let range = format.videoSupportedFrameRateRanges.first else { return requested }
    return min(max(requested, range.minFrameRate), range.maxFrameRate)
  }

  private static func actualFrameRate(device: AVCaptureDevice) -> Double {
    let duration = device.activeVideoMinFrameDuration
    guard duration.timescale != 0, duration.value != 0 else { return 0 }
    return Double(duration.timescale) / Double(duration.value)
  }

  fileprivate struct DeliveredFrame: Sendable {
    let width: Int
    let height: Int
    let pixelFormat: String
  }

  /// Starts `session`, waits for exactly one delivered sample buffer (or
  /// `timeoutSeconds`), then stops the session. Mirrors
  /// `CameraCaptureSource.start()`'s captureQueue-dispatched
  /// `startRunning()` pattern — blocking AVFoundation calls never touch the
  /// actor's own executor or the caller's task directly.
  private static func captureOneFrame(
    session: AVCaptureSession,
    output: AVCaptureVideoDataOutput,
    queue: DispatchQueue,
    timeoutSeconds: Double
  ) async throws -> DeliveredFrame {
    let sessionBox = ProbeSessionBox(session)

    let frame: DeliveredFrame? = await withCheckedContinuation { continuation in
      let delegate = ProbeFrameDelegate(continuation: continuation)
      output.setSampleBufferDelegate(delegate, queue: queue)
      queue.async {
        sessionBox.session.startRunning()
      }
      queue.asyncAfter(deadline: .now() + timeoutSeconds) {
        delegate.timeOut()
      }
    }

    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      queue.async {
        if sessionBox.session.isRunning {
          sessionBox.session.stopRunning()
        }
        resume.resume()
      }
    }

    guard let frame else { throw ProbeError.timedOutWaitingForFrame }
    return frame
  }
}

/// See `CameraCaptureSource.SessionBox` for the `@unchecked Sendable`
/// rationale — identical pattern, applied to this probe's own transient
/// session. Declared at file scope (not nested in `CameraFormatProbe`), same
/// as `CameraCaptureSource.SessionBox`, so the retroactive `Sendable`
/// extension below can see it.
private final class ProbeSessionBox: @unchecked Sendable {
  let session: AVCaptureSession
  init(_ session: AVCaptureSession) { self.session = session }
}

/// Resumes the continuation with the first delivered frame's dimensions and
/// pixel format, or with `nil` on timeout. A plain `NSObject` delegate, not
/// the actor itself — same rationale as
/// `CameraCaptureSource.SampleBufferDelegate`: it runs on `queue`, must
/// never hop isolation domains, and its only state (the continuation, plus
/// a lock-guarded one-shot flag) is safe to share across threads.
private final class ProbeFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let continuation: CheckedContinuation<CameraFormatProbe.DeliveredFrame?, Never>
  private let lock = NSLock()
  private var resumed = false

  init(continuation: CheckedContinuation<CameraFormatProbe.DeliveredFrame?, Never>) {
    self.continuation = continuation
  }

  func timeOut() {
    resumeOnce(with: nil)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    resumeOnce(
      with: CameraFormatProbe.DeliveredFrame(
        width: width, height: height, pixelFormat: PixelFormatCode.string(from: pixelFormat)))
  }

  private func resumeOnce(with frame: CameraFormatProbe.DeliveredFrame?) {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    continuation.resume(returning: frame)
  }
}

// See the type-level documentation above for why `@unchecked Sendable` is safe here.
// Declared via a retroactive extension (rather than inline on the class) purely so the
// primary declaration line stays short enough that swiftlint's `opening_brace` rule (brace
// on the same line) and swift-format's line-length-driven wrapping don't fight each other —
// same precedent as `CameraCaptureSource.SampleBufferDelegate`.
extension ProbeFrameDelegate: @unchecked Sendable {}

/// Renders a `CVPixelBuffer`/`CMFormatDescription` four-character pixel
/// format code (e.g. `kCVPixelFormatType_32BGRA`) as the readable string
/// AVFoundation debugging output conventionally uses ("BGRA", "420v"),
/// rather than a raw integer a VoiceOver user would have to decode by hand.
enum PixelFormatCode {
  static func string(from code: UInt32) -> String {
    // swift-format requires trailing commas in multiline collection literals;
    // swiftlint's default forbids them. Same documented conflict as
    // ConfigStore.swift; format wins.
    // swiftlint:disable trailing_comma
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xff),
      UInt8((code >> 16) & 0xff),
      UInt8((code >> 8) & 0xff),
      UInt8(code & 0xff),
    ]
    // swiftlint:enable trailing_comma
    let characters = bytes.map { byte -> Character in
      (0x20...0x7e).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }
    return String(characters)
  }
}
