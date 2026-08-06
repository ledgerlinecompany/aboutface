import Foundation

/// One window of CPU/thermal sampling, reduced to the numbers §13 Phase 4
/// asks to have "measured and documented."
struct AcceptanceResourceWindow: Sendable, Equatable {
  var sampleCount: Int
  var averageCpuPercent: Double
  var peakCpuPercent: Double
  var thermalEvents: [AcceptanceThermalEvent]

  static let empty = AcceptanceResourceWindow(
    sampleCount: 0, averageCpuPercent: 0, peakCpuPercent: 0, thermalEvents: [])

  init(
    sampleCount: Int, averageCpuPercent: Double, peakCpuPercent: Double,
    thermalEvents: [AcceptanceThermalEvent]
  ) {
    self.sampleCount = sampleCount
    self.averageCpuPercent = averageCpuPercent
    self.peakCpuPercent = peakCpuPercent
    self.thermalEvents = thermalEvents
  }

  init(samples: [AcceptanceResourceSample], thermalEvents: [AcceptanceThermalEvent]) {
    let percents = samples.map(\.cpuPercent)
    self.init(
      sampleCount: samples.count,
      averageCpuPercent: percents.isEmpty
        ? 0 : percents.reduce(0, +) / Double(percents.count),
      peakCpuPercent: percents.max() ?? 0,
      thermalEvents: thermalEvents)
  }
}

/// Idle CPU/thermal measurement taken BEFORE the camera opens and again
/// AFTER it closes, so the session's own numbers can be read as an impact
/// rather than an absolute (maintainer, 2026-08-06).
///
/// ## Why this is not just padding the run
///
/// The first real 2-minute run reported 47% average CPU and a 64% peak. On
/// its own that number cannot be interpreted: it says nothing about how much
/// of the machine was already busy, and §13's criterion is explicitly about
/// "CPU and thermal IMPACT," which is a delta. A baseline turns one
/// uninterpretable number into a comparison.
///
/// ## What each window can and cannot tell you
///
/// **Honest limitation, stated because it would otherwise mislead:** CPU here
/// is `getrusage(RUSAGE_SELF)` — THIS process only. Before the camera opens
/// the process is doing essentially nothing, so the "before" window is
/// expected to read near zero, and a near-zero reading there is not evidence
/// of anything. It is recorded anyway because it is the honest floor the
/// session number is measured against, and because a non-zero reading there
/// WOULD be a finding.
///
/// The two genuinely informative signals are:
/// - **Thermal drift and recovery.** `ProcessInfo.thermalState` is
///   system-wide, so the before/session/after progression shows whether a
///   long session actually heats the machine and whether it comes back down
///   afterward — which is precisely what "thermal impact" means for a tool
///   meant to run through a two-hour call.
/// - **Does CPU return to idle after the session stops.** A process still
///   burning CPU in the "after" window has left something spinning — a timer,
///   a capture session that did not really stop, a task that outlived its
///   cancellation. Nothing else in this codebase would surface that.
enum AcceptanceBaseline {
  /// Samples for `seconds` at `intervalSeconds` and returns the reduced
  /// window. Returns `.empty` immediately for a non-positive duration, so
  /// `--baseline-seconds 0` genuinely skips the phase rather than degenerating
  /// into a single sample that looks like a measurement.
  static func measure(seconds: Double, intervalSeconds: Double) async -> AcceptanceResourceWindow {
    guard seconds > 0 else { return .empty }
    let sampler = AcceptanceResourceSampler(start: ContinuousClock.now)
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
      await sampler.sampleOnce()
      let remaining = AcceptanceElapsed.seconds(from: ContinuousClock.now, to: deadline)
      guard remaining > 0 else { break }
      do {
        try await Task.sleep(for: .seconds(min(intervalSeconds, remaining)), clock: .continuous)
      } catch {
        break
      }
    }
    await sampler.sampleOnce()
    let snapshot = await sampler.snapshot()
    return AcceptanceResourceWindow(
      samples: snapshot.samples, thermalEvents: snapshot.thermalEvents)
  }
}
