import Foundation

/// The platform-probe layer for §12.3's mismatch warning: republishes
/// `CMIOAllDevicesBusyReader.currentRunningStates()` on a poll timer as an
/// `AsyncStream`, so `CameraMismatchController` (App/) has one stream to
/// consume instead of managing its own polling `Task`. Same role
/// `CameraInUseMonitor` plays for the single-device reminder signal
/// (§12.2), adapted for a signal with no listener/KVO path of its own.
///
/// ## Why this is a poll loop, not a listener republisher like
/// `CameraInUseMonitor`
///
/// `CameraInUseMonitor` republishes a provider that can register a real
/// CoreMediaIO property listener (`CMIOCameraBusyProvider`) for ONE
/// specific, already-resolved device. §12.3's comparison needs a reading
/// for EVERY enumerable device at once, re-enumerated on every read because
/// the device list itself can change (Continuity Camera connecting/
/// disconnecting — same rationale `CMIOPropertyReader.enumerateDeviceHandles()`'s
/// doc comment gives). Nothing in `CMIOPropertyReader` registers a listener
/// across "every device, including ones that don't exist yet," so a poll
/// loop is the only mechanism available, not a restraint being relaxed —
/// see `CMIOPropertyReader.swift`'s own doc comment for why every call
/// there is impure and only compile-tested.
///
/// ## Poll cadence reuses `Config.Camera.busyPollIntervalSeconds`
///
/// Deliberately not a new tunable: this is the same "how often is it
/// reasonable to ask CoreMediaIO about device state" question
/// `AVCaptureDeviceBusyProvider`/`CMIOCameraBusyProvider`'s polling
/// fallback already answers via that field, and inventing a second cadence
/// knob for what is conceptually the same question would violate §0's "no
/// numeric threshold is hardcoded" in spirit even though it would
/// technically be its own `Config` field. The PR brief's "do not add an
/// always-on high-frequency timer" restraint is satisfied the same way
/// `CMIOCameraBusyProvider`'s polling fallback satisfies it: this loop only
/// runs between `start()` and `stop()`, which `CameraMismatchController`
/// calls only while the Setup window exists (see that controller's doc
/// comment) — never while About Face is backgrounded with no window open.
///
/// ## Concurrency
///
/// An `actor`, not `@unchecked Sendable` like `CMIOCameraBusyProvider` —
/// unlike that type, this one has no CoreMediaIO listener block running on
/// its own `DispatchQueue`; the only concurrent activity is this actor's own
/// poll `Task`, so ordinary actor isolation is enough. Per the CLAUDE.md
/// toolchain rule, the poll `Task` calls
/// `CMIOAllDevicesBusyReader.currentRunningStates()` (a CoreMediaIO-backed
/// call) and only ever hands the result across as `[CMIODeviceRunningState]`
/// — an explicit `Sendable` value type this module declares itself, never an
/// SDK type relied on for its own `Sendable` conformance.
public actor CameraMismatchMonitor {
  public nonisolated let readings: AsyncStream<[CMIODeviceRunningState]>

  private let continuation: AsyncStream<[CMIODeviceRunningState]>.Continuation
  private var pollTask: Task<Void, Never>?

  public init() {
    let (stream, continuation) = AsyncStream<[CMIODeviceRunningState]>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.readings = stream
    self.continuation = continuation
  }

  /// Idempotent. Yields an immediate snapshot, then continues polling every
  /// `intervalSeconds` until `stop()`.
  public func start(intervalSeconds: Double) {
    guard pollTask == nil else { return }
    let continuation = self.continuation
    continuation.yield(CMIOAllDevicesBusyReader.currentRunningStates())
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(intervalSeconds))
        if Task.isCancelled { break }
        continuation.yield(CMIOAllDevicesBusyReader.currentRunningStates())
      }
    }
  }

  /// Idempotent. Cancels the poll `Task` and finishes `readings`.
  public func stop() {
    pollTask?.cancel()
    pollTask = nil
    continuation.finish()
  }
}
