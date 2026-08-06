import AboutFaceCore
import Foundation

/// Prints `acceptance`'s end-of-run report: plain text, ONE FACT PER LINE,
/// no tables, no ASCII art (PR brief: "it is read in Terminal with
/// VoiceOver"). A table's meaning lives in row/column alignment a screen
/// reader does not preserve; every line here is a complete, independently
/// readable sentence instead.
enum AcceptanceSummary {
  /// Everything a completed (or early-terminated) run has to report.
  /// Assembled by `AcceptanceCommand` from its various recorders/samplers;
  /// kept as one plain struct so `print(_:)` and
  /// `AcceptanceSessionStore`/`AcceptanceSessionLog`'s JSON encoding both
  /// read from the identical values, never two independently-computed
  /// summaries that could drift apart.
  struct Data {
    var requestedMinutes: Double
    var actualElapsedSeconds: Double
    var completedFullDuration: Bool
    var terminationReason: String?

    var requestedWidth: Int
    var requestedHeight: Int
    var requestedFrameRateFps: Double
    var rawFrameCount: Int
    var achievedRawCaptureFps: Double?
    var requestedAnalysisHz: Double?
    var analyzedFrameCount: Int
    var achievedAnalysisFps: Double
    var observedDimensions: [String]

    var stateCounts: [SignalState: Int]
    var faceLostEpisodes: Int
    var longestFaceLostMs: Int
    var totalFaceLostMs: Int

    var resourceSampleCount: Int
    var averageCpuPercent: Double?
    var peakCpuPercent: Double?
    var thermalEvents: [AcceptanceThermalEvent]
    /// Idle windows measured before the camera opened and after it closed —
    /// see `AcceptanceBaseline`'s doc comment for what each can and cannot
    /// tell you. `.empty` when `--baseline-seconds 0` skipped the phase.
    var baselineBefore: AcceptanceResourceWindow
    var baselineAfter: AcceptanceResourceWindow

    var report: AcceptanceReport
  }

  static func print(_ data: Data) {
    printHeader(data)
    printCapture(data)
    printSignal(data)
    printResources(data)
    printAcceptance(data.report)
  }

  private static func printHeader(_ data: Data) {
    if !data.completedFullDuration {
      Swift.print(String(repeating: "!", count: 78))
      Swift.print("RUN DID NOT COMPLETE THE REQUESTED \(data.requestedMinutes) MINUTES.")
      Swift.print("reason: \(data.terminationReason ?? "unknown")")
      Swift.print(
        "elapsed \(Self.formatted(data.actualElapsedSeconds / 60)) of \(data.requestedMinutes) "
          + "minutes requested.")
      Swift.print("DO NOT treat the report below as a complete acceptance run.")
      Swift.print(String(repeating: "!", count: 78))
    }
    Swift.print("acceptance run: requestedMinutes=\(data.requestedMinutes)")
    Swift.print("acceptance run: actualElapsedSeconds=\(Self.formatted(data.actualElapsedSeconds))")
    Swift.print("acceptance run: completedFullDuration=\(data.completedFullDuration)")
  }

  private static func printCapture(_ data: Data) {
    Swift.print(
      "capture: requestedWidth=\(data.requestedWidth) requestedHeight=\(data.requestedHeight)")
    Swift.print("capture: requestedFrameRateFps=\(Self.formatted(data.requestedFrameRateFps))")
    Swift.print("capture: rawFrameCount=\(data.rawFrameCount)")
    if let fps = data.achievedRawCaptureFps {
      Swift.print("capture: achievedRawCaptureFps=\(Self.formatted(fps))")
    } else {
      Swift.print("capture: achievedRawCaptureFps=unavailable (fewer than 2 raw frames arrived)")
    }
    Swift.print(
      "capture: requestedAnalysisHz="
        + (data.requestedAnalysisHz.map { Self.formatted($0) } ?? "every captured frame"))
    Swift.print("capture: analyzedFrameCount=\(data.analyzedFrameCount)")
    Swift.print("capture: achievedAnalysisFps=\(Self.formatted(data.achievedAnalysisFps))")
    if data.observedDimensions.count > 1 {
      Swift.print(
        "capture: WARNING delivered format changed mid-stream: "
          + data.observedDimensions.joined(separator: " then "))
    } else {
      Swift.print(
        "capture: deliveredFormatStableAcrossRun=yes (\(data.observedDimensions.first ?? "unknown"))"
      )
    }
  }

  private static func printSignal(_ data: Data) {
    let order: [SignalState] = [.ok, .lowConfidence, .noFace, .noSignal]
    for state in order {
      Swift.print("signal: \(state)=\(data.stateCounts[state] ?? 0) frames")
    }
    Swift.print("signal: faceLostEpisodes=\(data.faceLostEpisodes)")
    Swift.print("signal: longestFaceLostMs=\(data.longestFaceLostMs)")
    Swift.print("signal: totalFaceLostMs=\(data.totalFaceLostMs)")
  }

  private static func printResources(_ data: Data) {
    Swift.print("resources: cpuSampleCount=\(data.resourceSampleCount)")
    Swift.print(
      "resources: averageCpuPercent="
        + (data.averageCpuPercent.map { Self.formatted($0) } ?? "unavailable"))
    Swift.print(
      "resources: peakCpuPercent="
        + (data.peakCpuPercent.map { Self.formatted($0) } ?? "unavailable")
    )
    if data.thermalEvents.isEmpty {
      Swift.print("resources: thermalStateChanges=none observed")
    } else {
      for event in data.thermalEvents {
        Swift.print("resources: thermalState t=\(event.elapsedMs)ms -> \(event.state)")
      }
    }
    Self.printBaselines(data)
  }

  /// §13 asks for CPU/thermal IMPACT, which is a delta -- the session's own
  /// numbers mean nothing without a floor to read them against (maintainer,
  /// 2026-08-06). See `AcceptanceBaseline` for why the "before" CPU figure is
  /// expected to be near zero and what the two windows genuinely show.
  private static func printBaselines(_ data: Data) {
    Self.printWindow("baselineBefore", data.baselineBefore)
    Self.printWindow("baselineAfter", data.baselineAfter)
    if let sessionAverage = data.averageCpuPercent, data.baselineBefore.sampleCount > 0 {
      let delta = sessionAverage - data.baselineBefore.averageCpuPercent
      Swift.print("resources: sessionMinusBaselineAvgCpuPercent=" + Self.formatted(delta))
    }
    if data.baselineAfter.sampleCount > 0 {
      Swift.print(
        "resources: note -- a non-trivial baselineAfter CPU figure means this process was still "
          + "busy after the session stopped (a timer, task, or capture session that outlived its "
          + "cancellation); thermal recovery across the two baselines is the other signal here.")
    }
  }

  private static func printWindow(_ label: String, _ window: AcceptanceResourceWindow) {
    guard window.sampleCount > 0 else {
      Swift.print("resources: \(label)=skipped (--baseline-seconds 0)")
      return
    }
    Swift.print(
      "resources: \(label) sampleCount=\(window.sampleCount) "
        + "averageCpuPercent=" + Self.formatted(window.averageCpuPercent) + " "
        + "peakCpuPercent=" + Self.formatted(window.peakCpuPercent))
    if window.thermalEvents.isEmpty {
      Swift.print("resources: \(label) thermalStateChanges=none observed")
    } else {
      for event in window.thermalEvents {
        Swift.print("resources: \(label) thermalState t=\(event.elapsedMs)ms -> \(event.state)")
      }
    }
  }

  private static func printAcceptance(_ report: AcceptanceReport) {
    Swift.print(
      "acceptance: referenceEpisodeStartMs="
        + (report.referenceEpisodeStartMs.map(String.init) ?? "unknown"))
    Swift.print(
      "acceptance: referenceEpisodeStartIsInferred=\(report.referenceEpisodeStartIsInferred) "
        + "(inferred means this instrument did not directly observe when the face was actually "
        + "lost -- see the rung 1 note below)")
    for rung in report.rungs {
      Swift.print("acceptance rung \(rung.rung.rawValue): matched=\(rung.matched)")
      Swift.print("acceptance rung \(rung.rung.rawValue): \(rung.note)")
    }
    if report.strayRendererActivityDuringStop.isEmpty {
      Swift.print("acceptance: strayRendererActivityDuringStop=none (silence was total)")
    } else {
      Swift.print(
        "acceptance: WARNING strayRendererActivityDuringStop="
          + "\(report.strayRendererActivityDuringStop.count) event(s) -- the STOP was not silent:")
      for event in report.strayRendererActivityDuringStop {
        Swift.print("acceptance:   " + AcceptanceDescribe.event(event))
      }
    }
    // §6.1's heartbeat reported as a COUNT, not one line each: a 30-minute
    // run produces ~170 and they would bury the list below, which is the one
    // a human actually has to read. A run with zero across a long placed
    // stretch would itself be a finding, so the count is stated either way.
    if report.heartbeats.isEmpty {
      Swift.print("acceptance: livenessHeartbeats=0")
    } else {
      let first = report.heartbeats.first?.elapsedMs ?? 0
      let last = report.heartbeats.last?.elapsedMs ?? 0
      Swift.print(
        "acceptance: livenessHeartbeats=\(report.heartbeats.count) "
          + "(first at \(first)ms, last at \(last)ms) -- §6.1 liveness, expected while placed")
    }
    if report.unexplainedEvents.isEmpty {
      Swift.print("acceptance: unexplainedEvents=none -- nothing else fired")
    } else {
      Swift.print(
        "acceptance: unexplainedEvents=\(report.unexplainedEvents.count) -- everything else that fired:"
      )
      for event in report.unexplainedEvents {
        Swift.print("acceptance:   " + AcceptanceDescribe.event(event))
      }
    }
  }

  private static func formatted(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
