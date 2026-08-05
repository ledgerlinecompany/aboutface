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
