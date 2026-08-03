import AVFoundation
import CoreMedia
import CoreVideo

/// `ProbeSessionBox`, `ProbeDeviceBox`, `ProbeFrameDelegate`, and
/// `PixelFormatCode` — split out of `CameraFormatProbe.swift` into this
/// file purely to stay under SwiftLint's `file_length` limit. These are
/// exactly as if they lived inline in that file; see
/// `CameraFormatProbe`'s own doc comments for the concurrency rationale.
/// `internal` (not `private`), since `CameraFormatProbe.swift` constructs
/// them from a different file.

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
