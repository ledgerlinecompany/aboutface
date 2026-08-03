import AVFoundation
import CoreMedia

/// `CameraSessionBox`, `CameraDeviceBox`, and `CameraSampleBufferDelegate` —
/// split out of `CameraCaptureSource.swift` into this file purely to stay
/// under SwiftLint's `file_length` limit. These are exactly as if they
/// lived inline in that file; see `CameraCaptureSource`'s own doc comments
/// for why each of these ownership-transfer wrappers exists. Named with a
/// `Camera` prefix (rather than the shorter `SessionBox`/`DeviceBox` used
/// when these lived inline) to avoid colliding with the unrelated,
/// file-private `DeviceBox` in `AVCaptureDeviceBusyProvider.swift` — these
/// are `internal`, not `private`, since they now need to be visible from
/// both this file and `CameraCaptureSource.swift`.

/// A `Sendable` wrapper around the actor-owned `AVCaptureSession`, used only
/// to move the session across the `captureQueue.async` boundary in
/// `start()`/`stop()`. `AVCaptureSession` predates Swift concurrency and
/// isn't `Sendable`-annotated, but the session is designed to have its
/// blocking `startRunning()`/`stopRunning()` calls invoked from a queue
/// other than the one that configured it; `@unchecked Sendable` here
/// reflects that documented Apple usage pattern (dedicated-queue lifecycle
/// calls), not a bypass of an actual data race.
final class CameraSessionBox: @unchecked Sendable {
  let session: AVCaptureSession

  init(_ session: AVCaptureSession) {
    self.session = session
  }
}

/// A `Sendable` wrapper around the actor-resolved `AVCaptureDevice`, used
/// only to move it across the `captureQueue.async` boundary in `start()` so
/// frame durations can be set AFTER `startRunning()` (see
/// `CameraCaptureSource.configureSession`'s doc comment for why that
/// ordering matters). `AVCaptureDevice` predates Swift concurrency and
/// isn't reliably `Sendable`-annotated across SDKs (the CLAUDE.md
/// toolchain-skew rule); same ownership-transfer rationale as
/// `CameraSessionBox` above and `AVCaptureDeviceBusyProvider`'s own
/// (unrelated, file-private) `DeviceBox` — a one-shot handoff into a single
/// queue's sequential closure, not concurrent sharing.
final class CameraDeviceBox: @unchecked Sendable {
  let device: AVCaptureDevice

  init(_ device: AVCaptureDevice) {
    self.device = device
  }
}

/// Forwards sample buffers from `AVCaptureVideoDataOutput`'s delegate
/// callback directly into `CameraCaptureSource`'s `AsyncStream.Continuation`.
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
final class CameraSampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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

// See `CameraSampleBufferDelegate`'s own documentation above for why
// `@unchecked Sendable` is safe here. Declared via a retroactive extension
// (rather than inline on the class) purely so the primary declaration line
// stays short enough that swiftlint's `opening_brace` rule (brace on the
// same line) and swift-format's line-length-driven wrapping don't fight
// each other.
extension CameraSampleBufferDelegate: @unchecked Sendable {}
