import Darwin
import Foundation

/// §13 Phase 4's other acceptance clause: "CPU and thermal impact measured
/// and documented" — as numbers, not impressions (PR brief). Samples this
/// process's own CPU usage and the system thermal state at a fixed cadence
/// for the whole `aboutface-cli acceptance` session.
///
/// ## CPU: differenced `getrusage`, not a snapshot
///
/// `getrusage(RUSAGE_SELF)` reports CUMULATIVE user+system CPU time since
/// process start, in absolute seconds — not a percentage, and not reset per
/// call. A percentage-over-an-interval reading (the number that is actually
/// useful for "is this eating a laptop's battery on a two-hour call") comes
/// from DIFFERENCING two cumulative readings and dividing by the WALL-CLOCK
/// interval between them, exactly as `sampleOnce()` does below. A single
/// snapshot at the end of a 30-minute run would only give an all-session
/// average with no visibility into whether load spiked partway through
/// (e.g. during the away episode's Center Stage/analysis churn); per-sample
/// readings let the summary report both average AND peak.
///
/// ## Thermal: every distinct state, not just the final one
///
/// `ProcessInfo.processInfo.thermalState` is a live read with no history of
/// its own. Recording only the value at the end of the run would silently
/// discard a `.serious`/`.critical` excursion that resolved back to
/// `.nominal` before the session ended — exactly the kind of transient
/// impact §13's "measured and documented" is asking for. `sampleOnce()`
/// appends a new `AcceptanceThermalEvent` only on a value CHANGE, the same
/// transitions-not-samples discipline `AcceptanceAwayPoller` uses for
/// `userLikelyAway`.
///
/// An actor: sampling runs on its own periodic `Task` (owned by
/// `aboutface-cli acceptance`, see that command's file) while the CLI's
/// main loop and other instrumentation run concurrently; `samples`/
/// `thermalEvents`/the differencing state all need the same synchronization
/// an actor gives for free.
actor AcceptanceResourceSampler {
  private let start: ContinuousClock.Instant
  private var lastCPUSeconds: Double?
  private var lastSampleInstant: ContinuousClock.Instant?
  private var lastThermalState: ProcessInfo.ThermalState?

  private var samples: [AcceptanceResourceSample] = []
  private var thermalEvents: [AcceptanceThermalEvent] = []

  init(start: ContinuousClock.Instant) {
    self.start = start
  }

  /// Takes one reading. The first call establishes a baseline only (no
  /// meaningful interval to divide by yet) and records the thermal state at
  /// session start; every call after that appends one CPU sample and, if
  /// the thermal state changed, one thermal event.
  func sampleOnce() {
    let now = ContinuousClock.now
    let elapsedMs = AcceptanceElapsed.milliseconds(from: start, to: now)
    let cpuSeconds = Self.currentProcessCPUSeconds()

    if let lastCPUSeconds, let lastSampleInstant {
      let intervalSeconds = AcceptanceElapsed.seconds(from: lastSampleInstant, to: now)
      if intervalSeconds > 0 {
        let cpuPercent = (cpuSeconds - lastCPUSeconds) / intervalSeconds * 100
        samples.append(AcceptanceResourceSample(elapsedMs: elapsedMs, cpuPercent: cpuPercent))
      }
    }
    lastCPUSeconds = cpuSeconds
    lastSampleInstant = now

    let thermal = ProcessInfo.processInfo.thermalState
    if thermal != lastThermalState {
      lastThermalState = thermal
      thermalEvents.append(AcceptanceThermalEvent(elapsedMs: elapsedMs, state: thermal))
    }
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  func snapshot() -> (samples: [AcceptanceResourceSample], thermalEvents: [AcceptanceThermalEvent])
  {
    // swiftlint:enable opening_brace
    (samples, thermalEvents)
  }

  /// Cumulative user+system CPU time for THIS process, seconds.
  /// `getrusage`/`RUSAGE_SELF`/`rusage` come from `Darwin` (this package
  /// targets macOS only — see `Package.swift`), not `Foundation`.
  nonisolated static func currentProcessCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }
}

/// One CPU reading — the percentage of wall-clock time this process spent
/// on-CPU (user + system) over the interval ending at `elapsedMs`, per
/// `AcceptanceResourceSampler.sampleOnce()`'s doc comment.
struct AcceptanceResourceSample: Sendable, Equatable {
  let elapsedMs: Int
  let cpuPercent: Double
}

/// One thermal state CHANGE (see `AcceptanceResourceSampler`'s own doc
/// comment for why only changes are recorded).
struct AcceptanceThermalEvent: Sendable, Equatable {
  let elapsedMs: Int
  let state: ProcessInfo.ThermalState
}
