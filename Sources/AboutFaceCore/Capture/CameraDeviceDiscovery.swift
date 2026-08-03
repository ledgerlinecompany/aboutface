/// Publishes live camera device snapshots (§12.1), backed by an injected
/// `CameraDeviceProvider` — `AVCaptureDeviceProvider` in production, a fake
/// in tests (CI rule: no test may require a live camera).
///
/// This is deliberately a thin actor: all the AVFoundation-facing work
/// (KVO registration, `DiscoverySession` lifecycle) lives in the provider;
/// this type only owns the publish-a-stream-of-snapshots policy, so it can
/// be exercised in tests with a fake provider that fires canned device-list
/// changes.
public actor CameraDeviceDiscovery {
  /// A single `AsyncStream` instance for the lifetime of this actor —
  /// matches `CaptureSource.frames`' documented contract, so multiple
  /// observers share one underlying stream. Buffers only the newest
  /// snapshot: a device list is state, not an event log, so a slow consumer
  /// should see "what's true now," not a backlog of superseded lists.
  public nonisolated let devices: AsyncStream<[CameraDeviceDescriptor]>

  private let continuation: AsyncStream<[CameraDeviceDescriptor]>.Continuation
  private let provider: any CameraDeviceProvider
  private var token: CameraDeviceObservationToken?

  public init(provider: any CameraDeviceProvider = AVCaptureDeviceProvider()) {
    self.provider = provider
    let (stream, continuation) = AsyncStream<[CameraDeviceDescriptor]>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.devices = stream
    self.continuation = continuation
  }

  /// Idempotent. Yields an immediate snapshot from `provider.currentDevices()`,
  /// then a fresh full snapshot on every subsequent observed change —
  /// Continuity Camera devices coming and going, an external webcam being
  /// plugged in, etc.
  public func start() {
    guard token == nil else { return }
    continuation.yield(provider.currentDevices())
    let continuation = self.continuation
    token = provider.startObserving { snapshot in
      continuation.yield(snapshot)
    }
  }

  /// Idempotent. Stops observation and finishes `devices`.
  public func stop() {
    if let token {
      provider.stopObserving(token)
    }
    token = nil
    continuation.finish()
  }
}
