import Foundation

/// Protocol seam for §12.2's camera-in-use signal
/// (`AVCaptureDevice.isInUseByAnotherApplication`), mirroring
/// `CameraDeviceProvider`'s shape: `AVCaptureDeviceBusyProvider` is the real
/// conformance, tests use a fake that delivers canned busy/free transitions
/// (CI rule: no test may require a live camera, and genuinely exercising
/// "another app grabbed the camera" needs a second real process — see that
/// type's doc comment).
///
/// **Currently unwired** — see `CameraGating.swift`'s doc comment. §12.2
/// found that `isInUseByAnotherApplication`, the signal
/// `AVCaptureDeviceBusyProvider` (the real conformance) reads, does not
/// detect a conferencing app on current macOS. Read that finding before
/// wiring this protocol's consumers back into a live activation path.
public protocol CameraBusyProvider: Sendable {
  /// A synchronous read of the current busy state.
  func currentValue() -> Bool

  /// Begins observing for busy-state changes, invoking `onChange` with the
  /// new value each time it changes. `onChange` may be invoked from any
  /// thread — same contract as `CameraDeviceProvider.startObserving`.
  ///
  /// Returns which observation path actually got established, per §12.2:
  /// "Verify empirically whether this property is genuinely KVO-observable.
  /// If not, poll at 1 Hz. Document which path was taken."
  func startObserving(
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> CameraBusyObservationStart

  /// Explicitly stops observation associated with `token`. Idempotent.
  func stopObserving(_ token: CameraBusyObservationToken)
}

/// Which mechanism is actually delivering busy-state changes right now.
public enum CameraBusyObservationPath: Sendable, Equatable {
  /// KVO registration on `isInUseByAnotherApplication` succeeded.
  /// `AVCaptureDeviceBusyProvider`'s doc comment explains why "registration
  /// succeeded" is the strongest claim obtainable without a second app
  /// physically grabbing the camera in a live session.
  case kvo
  /// `CMIOObjectAddPropertyListenerBlock` registration on
  /// `kCMIODevicePropertyDeviceIsRunningSomewhere` succeeded. A distinct
  /// case from `.kvo` rather than reusing it — CoreMediaIO's block-listener
  /// mechanism is a genuinely different registration API from Cocoa KVO,
  /// and §12.2 explicitly asks which path a conformance actually took.
  /// `CMIOCameraBusyProvider`'s doc comment explains what "registration
  /// succeeded" does and doesn't verify here.
  case cmioListener
  /// Neither `.kvo` nor `.cmioListener` was established (KVO unavailable;
  /// CMIO listener registration failed; or `forcePolling` overrode either —
  /// see `AVCaptureDeviceBusyProvider.init`/`CMIOCameraBusyProvider.init`) —
  /// falling back to timed reads.
  case polling
}

/// What `startObserving` hands back: the live token plus which path it
/// established.
public struct CameraBusyObservationStart: Sendable {
  public let token: CameraBusyObservationToken
  public let path: CameraBusyObservationPath

  public init(token: CameraBusyObservationToken, path: CameraBusyObservationPath) {
    self.token = token
    self.path = path
  }
}

/// Opaque handle returned by `CameraBusyProvider.startObserving`. See
/// `CameraDeviceObservationToken`'s doc comment for the identical rationale.
public final class CameraBusyObservationToken: Sendable {
  let id = UUID()

  public init() {}
}
