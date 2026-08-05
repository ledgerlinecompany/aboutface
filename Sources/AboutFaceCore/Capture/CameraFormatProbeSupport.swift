import AVFoundation
import CoreMedia
import CoreVideo

/// `CameraFormatProbe.Result`, `ProbeSessionBox`, `ProbeDeviceBox`,
/// `ProbeFrameDelegate`, and `PixelFormatCode` — split out of
/// `CameraFormatProbe.swift` into this file purely to stay under
/// SwiftLint's `file_length` limit. These are exactly as if they lived
/// inline in that file; see `CameraFormatProbe`'s own doc comments for the
/// concurrency rationale. `internal` (not `private`), since
/// `CameraFormatProbe.swift` constructs them from a different file.

extension CameraFormatProbe {
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
    /// is what actually governs the granted resolution on macOS (see
    /// `CameraFormatProbe`'s type-level doc comment).
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
    /// pre-start claim (see `CameraFormatProbe`'s type-level doc comment
    /// for why that ordering matters on macOS).
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

    /// §12.2's replacement signal (`kCMIODevicePropertyDeviceIsRunningSomewhere`)
    /// for the SAME device, read at the SAME "before this probe opened its
    /// own session" point as `isInUseByAnotherApplication` above — so the
    /// two can be compared side by side against the same instant. Per
    /// §12.2's finding, expect these to disagree if another app is
    /// genuinely streaming: `isInUseByAnotherApplication` reads `false`
    /// regardless, while this reads `.running`.
    public let cmioRunningSomewhereBeforeOpen: CMIORunningSomewhereReading

    /// The same CMIO reading, read again AFTER this probe's own session
    /// started and a frame was delivered (same post-start-and-post-frame
    /// point `deviceGrantedWidth`/etc. are read at) — while our own session
    /// is still open. Per §12.2's "any process, including us" asymmetry,
    /// this is expected to read `.running` even if no other app is using
    /// the camera, simply because THIS probe is now streaming. Reporting
    /// both readings, unambiguously labeled, makes that self-detection
    /// effect visible instead of confusing (see `ProbeCameraCommand`).
    public let cmioRunningSomewhereAfterOpen: CMIORunningSomewhereReading

    /// One `CMIORunningSomewhereReading` per CMIO-enumerable device
    /// (§12.3's cross-device query), read at the same "before this probe
    /// opened its own session" point as `cmioRunningSomewhereBeforeOpen` —
    /// the point at which a cross-device comparison is actually meaningful,
    /// since none of the readings are contaminated by this probe's own
    /// capture yet.
    public let cmioAllDeviceReadings: [CMIODeviceRunningState]

    /// §12.5's read layer: `CenterStageReader.read(forUniqueID:)` for the
    /// SAME device, read at the SAME "before this probe opened its own
    /// session" point as `cmioRunningSomewhereBeforeOpen`. Per
    /// `AVCaptureDevice.isCenterStageActive`'s header, this instance
    /// property "depends on the device's current configuration" -- with no
    /// session open, that configuration is whatever the device defaulted to
    /// before this probe touched it, which may or may not be a
    /// Center-Stage-capable format. Only comparing this against
    /// `centerStageAfterOpen` can show whether opening OUR session (or the
    /// specific requested format) changes anything.
    public let centerStageBeforeOpen: CenterStageDeviceReading

    /// The same read, taken again AFTER this probe's own session started
    /// and a frame was delivered -- the SAME post-start-and-post-frame,
    /// pre-stop point `cmioRunningSomewhereAfterOpen` is read at. This
    /// pairing is the entire point of §12.5's read layer: it is entirely
    /// possible for `deviceReportsActive` to read `false` before any
    /// session is open and `true` once a Center-Stage-capable session is
    /// running, or for a low-resolution Monitor format to turn it off where
    /// a higher-resolution Setup format would not. Only the pair can show
    /// that -- neither reading alone can. `.deviceNotFound` here (rather
    /// than at `centerStageBeforeOpen`) would mean the device disconnected
    /// during this probe's frame wait -- itself a meaningful finding, not
    /// noise.
    public let centerStageAfterOpen: CenterStageDeviceReading

    /// One `CenterStageDeviceSummary` per enumerable video device (§12.5's
    /// per-device breakdown, mirroring `cmioAllDeviceReadings`'s per-device
    /// shape), read at the same "before this probe opened its own session"
    /// point as `centerStageBeforeOpen` -- lets the maintainer identify
    /// which of his cameras is even Center-Stage-capable before this
    /// probe's own capture can affect any of their readings.
    public let centerStageDeviceReadings: [CenterStageDeviceSummary]
  }
}

/// See `CameraCaptureSource`'s `CameraSessionBox` for the `@unchecked
/// Sendable` rationale — identical pattern, applied to this probe's own
/// transient session.
final class ProbeSessionBox: @unchecked Sendable {
  let session: AVCaptureSession
  init(_ session: AVCaptureSession) { self.session = session }
}

/// See `CameraCaptureSource`'s `CameraDeviceBox` for the `@unchecked
/// Sendable` rationale — identical pattern, applied to this probe's own
/// resolved device: a one-shot handoff into `captureOneFrame`'s queue
/// closure so frame durations can be set (and the granted format read
/// back) AFTER `startRunning()`.
final class ProbeDeviceBox: @unchecked Sendable {
  let device: AVCaptureDevice
  init(_ device: AVCaptureDevice) { self.device = device }
}

/// Resumes the continuation with the first delivered frame's dimensions and
/// pixel format, or with `nil` on timeout. A plain `NSObject` delegate, not
/// the actor itself — same rationale as `CameraCaptureSource`'s
/// `CameraSampleBufferDelegate`: it runs on `queue`, must never hop
/// isolation domains, and its only state (the continuation, plus a
/// lock-guarded one-shot flag) is safe to share across threads.
final class ProbeFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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
// same precedent as `CameraCaptureSource`'s `CameraSampleBufferDelegate`.
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
