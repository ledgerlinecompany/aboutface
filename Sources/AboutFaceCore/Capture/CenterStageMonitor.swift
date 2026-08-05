import Foundation

/// The platform-probe layer for §12.5's app-side Center Stage wiring:
/// republishes `CenterStageReader.read(forUniqueID:)` for ONE selected
/// device on a poll timer as an `AsyncStream`, so `CenterStageController`
/// (App/) has one stream to consume instead of managing its own polling
/// `Task`. Modeled closely on `CameraMismatchMonitor` — see that type's doc
/// comment for the fuller "why a poll loop, not a listener republisher"
/// argument, which applies here for an even more basic reason: nothing in
/// AVFoundation exposes a KVO/notification path for another process's
/// `isCenterStageActive` at all (unlike `isInUseByAnotherApplication`, it is
/// not `@objc dynamic`), so a poll loop is the only mechanism available, full
/// stop — not a restraint being relaxed.
///
/// ## Poll cadence reuses `Config.Camera.busyPollIntervalSeconds`
///
/// Same reasoning as `CameraMismatchMonitor`'s own doc comment: this is the
/// same "how often is it reasonable to ask the platform about device state"
/// question, and inventing a second cadence knob for conceptually the same
/// question would violate §0's "no numeric threshold is hardcoded" in
/// spirit even though it would technically be its own `Config` field. This
/// loop only runs between `start()` and `stop()`, which `CenterStageController`
/// calls only while a camera is selected and a Setup window exists (see that
/// controller's doc comment) — never an always-on background timer.
///
/// ## Concurrency
///
/// An `actor`, same shape as `CameraMismatchMonitor` for the same reason:
/// the only concurrent activity is this actor's own poll `Task`. Per the
/// CLAUDE.md toolchain rule, the poll `Task` calls
/// `CenterStageReader.read(forUniqueID:)` (an AVFoundation-backed call) and
/// only ever hands the result across as `CenterStageDeviceReading` — an
/// explicit `Sendable` value type this module declares itself, never an SDK
/// type relied on for its own `Sendable` conformance.
public actor CenterStageMonitor {
  public nonisolated let readings: AsyncStream<CenterStageDeviceReading>

  private let continuation: AsyncStream<CenterStageDeviceReading>.Continuation
  private var pollTask: Task<Void, Never>?

  public init() {
    let (stream, continuation) = AsyncStream<CenterStageDeviceReading>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.readings = stream
    self.continuation = continuation
  }

  /// Idempotent. Yields an immediate reading for `uniqueID`, then continues
  /// polling every `intervalSeconds` until `stop()`.
  public func start(uniqueID: String, intervalSeconds: Double) {
    guard pollTask == nil else { return }
    let continuation = self.continuation
    continuation.yield(CenterStageReader.read(forUniqueID: uniqueID))
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(intervalSeconds))
        if Task.isCancelled { break }
        continuation.yield(CenterStageReader.read(forUniqueID: uniqueID))
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
