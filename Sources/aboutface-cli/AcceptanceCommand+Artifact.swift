import AboutFaceCore
import Foundation

// swift-format requires the brace on its own line after a wrapped function
// signature; swiftlint's opening_brace rule disagrees. Format wins (see
// FeedbackRouter.swift for the same disagreement) -- disabled for the whole
// file rather than function-by-function since every builder below has this
// exact shape.
// swiftlint:disable opening_brace
/// `Acceptance.writeArtifact(summaryData:config:)` — split out of
/// `AcceptanceCommand.swift` purely to keep that file's `run()` orchestration
/// readable and both files comfortably under SwiftLint's `file_length`
/// limit; everything here is still `Acceptance`'s own implementation. See
/// `AcceptanceArtifact.swift` for the on-disk `AcceptanceSessionLog` schema
/// this builds and appends to.
extension Acceptance {
  func writeArtifact(summaryData: AcceptanceSummary.Data, config: Config) throws {
    let url = URL(fileURLWithPath: json)
    var log = AcceptanceSessionStore.load(from: url)
    log.sessions.append(makeSessionRecord(summaryData: summaryData, config: config))
    try AcceptanceSessionStore.write(log, to: url)
    Swift.print("wrote session record to \(json)")
  }

  private func makeSessionRecord(summaryData: AcceptanceSummary.Data, config: Config)
    -> AcceptanceSessionLog.SessionRecord
  {
    AcceptanceSessionLog.SessionRecord(
      dateISO8601: ISO8601DateFormatter().string(from: Date()),
      configSource: configPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "defaults",
      configHash: AcceptanceSessionStore.configHash(config), requestedMinutes: minutes,
      actualElapsedSeconds: summaryData.actualElapsedSeconds,
      completedFullDuration: summaryData.completedFullDuration,
      terminationReason: summaryData.terminationReason,
      capture: captureRecord(summaryData), signal: signalRecord(summaryData),
      resources: resourceRecord(summaryData), acceptance: acceptanceRecord(summaryData.report))
  }

  private func captureRecord(_ summaryData: AcceptanceSummary.Data)
    -> AcceptanceSessionLog.CaptureRecord
  {
    AcceptanceSessionLog.CaptureRecord(
      requestedWidth: summaryData.requestedWidth, requestedHeight: summaryData.requestedHeight,
      requestedFrameRateFps: summaryData.requestedFrameRateFps,
      rawFrameCount: summaryData.rawFrameCount,
      achievedRawCaptureFps: summaryData.achievedRawCaptureFps,
      requestedAnalysisHz: summaryData.requestedAnalysisHz,
      analyzedFrameCount: summaryData.analyzedFrameCount,
      achievedAnalysisFps: summaryData.achievedAnalysisFps,
      observedDimensions: summaryData.observedDimensions)
  }

  private func signalRecord(_ summaryData: AcceptanceSummary.Data)
    -> AcceptanceSessionLog.SignalRecord
  {
    AcceptanceSessionLog.SignalRecord(
      stateCounts: Dictionary(
        uniqueKeysWithValues: summaryData.stateCounts.map { ("\($0.key)", $0.value) }),
      faceLostEpisodes: summaryData.faceLostEpisodes,
      longestFaceLostMs: summaryData.longestFaceLostMs, totalFaceLostMs: summaryData.totalFaceLostMs
    )
  }

  private func resourceRecord(_ summaryData: AcceptanceSummary.Data)
    -> AcceptanceSessionLog.ResourceRecord
  {
    AcceptanceSessionLog.ResourceRecord(
      sampleCount: summaryData.resourceSampleCount,
      averageCpuPercent: summaryData.averageCpuPercent, peakCpuPercent: summaryData.peakCpuPercent,
      thermalEvents: summaryData.thermalEvents.map {
        AcceptanceSessionLog.ThermalEventRecord(elapsedMs: $0.elapsedMs, state: "\($0.state)")
      })
  }

  private func acceptanceRecord(_ report: AcceptanceReport) -> AcceptanceSessionLog.AcceptanceRecord
  {
    AcceptanceSessionLog.AcceptanceRecord(
      referenceEpisodeStartMs: report.referenceEpisodeStartMs,
      referenceEpisodeStartIsInferred: report.referenceEpisodeStartIsInferred,
      rungs: report.rungs.map(AcceptanceSessionLog.RungRecord.init),
      unexplainedEvents: report.unexplainedEvents.map(AcceptanceSessionLog.EventRecord.init),
      strayRendererActivityDuringStop: report.strayRendererActivityDuringStop.map(
        AcceptanceSessionLog.EventRecord.init))
  }
}
// swiftlint:enable opening_brace
