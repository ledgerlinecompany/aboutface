import Foundation

/// Protocol seam between `CameraDeviceDiscovery` and whatever actually
/// enumerates cameras, so the discovery actor's snapshot-publishing logic
/// can be exercised with a mock in unit tests (CI rule: no test may require
/// a live camera). `AVCaptureDeviceProvider` is the real, `AVFoundation`
/// -backed conformance; tests use a fake that yields canned device lists.
///
/// Every method here returns/delivers `CameraDeviceDescriptor` — a plain
/// `Sendable` value — never a raw `AVCaptureDevice`. That is the boundary
/// the CLAUDE.md toolchain-skew rule asks for: a conformance may do whatever
/// it needs internally with non-`Sendable` AVFoundation types, but nothing
/// crosses out of it except values the compiler can verify are safe on
/// every toolchain, regardless of which SDK's `Sendable` annotations happen
/// to be in effect.
public protocol CameraDeviceProvider: Sendable {
  /// A synchronous snapshot of currently known devices, for the initial
  /// value before the first change notification (if any) arrives.
  func currentDevices() -> [CameraDeviceDescriptor]

  /// Begins observing for device list changes, invoking `onChange` with a
  /// fresh full snapshot each time the set of available devices changes.
  /// `onChange` may be invoked from any thread/queue — conformances MUST
  /// NOT assume a particular isolation context, and callers MUST NOT do
  /// anything in `onChange` beyond handing the (already-`Sendable`)
  /// snapshot across a boundary (e.g. into an actor-isolated method via
  /// `Task { await ... }`).
  ///
  /// Returns a token; observation stops when the token is deallocated or
  /// `stopObserving(_:)` is called with it, whichever comes first.
  func startObserving(
    onChange: @escaping @Sendable ([CameraDeviceDescriptor]) -> Void
  ) -> CameraDeviceObservationToken

  /// Explicitly stops observation associated with `token`. Idempotent.
  func stopObserving(_ token: CameraDeviceObservationToken)
}

/// Opaque handle returned by `CameraDeviceProvider.startObserving`. A class
/// (not a struct) so `AVCaptureDeviceProvider`'s conformance can give it
/// deinit-based cleanup as a backstop, matching the ownership-transfer
/// pattern documented on `CameraCaptureSource.SessionBox` — the token
/// itself carries no AVFoundation state across a boundary, only an opaque
/// identity a provider can look up internally.
public final class CameraDeviceObservationToken: Sendable {
  let id = UUID()

  public init() {}
}
