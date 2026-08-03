/// Publishes camera busy/free transitions (§12.2's platform-probe layer),
/// backed by an injected `CameraBusyProvider` — `AVCaptureDeviceBusyProvider`
/// in production, a fake in tests.
///
/// This is the "platform probe" half of §12.2's two strictly separated
/// layers. It is a thin republisher, deliberately: all the
/// KVO-vs-polling decision-making lives in the provider (see
/// `AVCaptureDeviceBusyProvider`'s doc comment for why that decision is
/// mostly "attempt KVO" plus a documented, config-keyed override rather than
/// genuine runtime detection); this type exists so callers have one
/// `AsyncStream<Bool>` to consume regardless of which path is live, and so
/// `activePath` is observable for logging/diagnostics (the probe-camera CLI
/// tool surfaces it — see `ProbeCameraCommand.swift`).
///
/// The **other** layer, `CameraGatingStateMachine`, is a separate, pure
/// (no `AVFoundation` import) type that turns this actor's busy/free stream
/// into mode-transition events — see that file's doc comment for why the
/// two are kept apart.
public actor CameraInUseMonitor {
  public nonisolated let busyStates: AsyncStream<Bool>

  private let continuation: AsyncStream<Bool>.Continuation
  private let provider: any CameraBusyProvider
  private var token: CameraBusyObservationToken?

  /// Which observation path is currently live — `nil` before `start()`.
  public private(set) var activePath: CameraBusyObservationPath?

  public init(provider: any CameraBusyProvider) {
    self.provider = provider
    let (stream, continuation) = AsyncStream<Bool>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.busyStates = stream
    self.continuation = continuation
  }

  /// Convenience over the real `AVCaptureDeviceBusyProvider`, for
  /// production callers that have a device ID but no provider to inject
  /// (tests inject a fake `CameraBusyProvider` directly via the designated
  /// `init(provider:)` instead).
  public init(
    deviceUniqueID: String,
    pollIntervalSeconds: Double = 1.0,
    forcePolling: Bool = false
  ) {
    self.init(
      provider: AVCaptureDeviceBusyProvider(
        deviceUniqueID: deviceUniqueID,
        pollIntervalSeconds: pollIntervalSeconds,
        forcePolling: forcePolling
      )
    )
  }

  /// Idempotent. Yields an immediate value from `provider.currentValue()`,
  /// records which path `provider.startObserving` established, then
  /// continues to yield on every subsequent observed change.
  public func start() {
    guard token == nil else { return }
    continuation.yield(provider.currentValue())
    let continuation = self.continuation
    let started = provider.startObserving { value in
      continuation.yield(value)
    }
    token = started.token
    activePath = started.path
  }

  /// Idempotent. Stops observation and finishes `busyStates`.
  public func stop() {
    if let token {
      provider.stopObserving(token)
    }
    token = nil
    activePath = nil
    continuation.finish()
  }
}
