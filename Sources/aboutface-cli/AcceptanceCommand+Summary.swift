import AboutFaceCore
import Foundation

/// `Acceptance`'s summary assembly, split out of `AcceptanceCommand.swift`
/// purely for SwiftLint's `type_body_length`/`function_body_length` budget,
/// which CI enforces as an ERROR (`swiftlint --strict`). Same precedent as
/// `AcceptanceCommand+Artifact.swift` next door; this is still `Acceptance`'s
/// own implementation.
extension Acceptance {
  /// Everything `makeSummaryData` needs, bundled — the parameter list
  /// otherwise exceeds SwiftLint's `function_parameter_count` limit. Same
  /// precedent as `CameraFormatProbe.CaptureRequest`; not otherwise
  /// meaningful as a standalone value.
  struct SummaryInputs {
    let modeSettings: CameraModeCaptureSettings
    let loopResult: AcceptanceRunLoopResult
    let resourceSamples: [AcceptanceResourceSample]
    let thermalEvents: [AcceptanceThermalEvent]
    let report: AcceptanceReport
    let baselineBefore: AcceptanceResourceWindow
    let baselineAfter: AcceptanceResourceWindow
  }

  func makeSummaryData(_ inputs: SummaryInputs) -> AcceptanceSummary.Data {
    let loopResult = inputs.loopResult
    let modeSettings = inputs.modeSettings
    let cpuPercents = inputs.resourceSamples.map(\.cpuPercent)
    return AcceptanceSummary.Data(
      requestedMinutes: minutes, actualElapsedSeconds: loopResult.actualElapsedSeconds,
      completedFullDuration: loopResult.completedFullDuration,
      terminationReason: loopResult.terminationReason, requestedWidth: modeSettings.width,
      requestedHeight: modeSettings.height, requestedFrameRateFps: modeSettings.frameRate,
      rawFrameCount: loopResult.rawFrameCount,
      achievedRawCaptureFps: loopResult.achievedRawCaptureFps,
      requestedAnalysisHz: modeSettings.analysisHz, analyzedFrameCount: loopResult.stats.frameCount,
      achievedAnalysisFps: Self.rate(
        count: loopResult.stats.frameCount, overSeconds: loopResult.actualElapsedSeconds),
      observedDimensions: loopResult.stats.observedDimensions.map { "\($0.width)x\($0.height)" },
      stateCounts: loopResult.stats.stateCounts,
      faceLostEpisodes: loopResult.stats.faceLostEpisodes,
      longestFaceLostMs: loopResult.stats.longestFaceLostMs,
      totalFaceLostMs: loopResult.stats.totalFaceLostMs,
      resourceSampleCount: inputs.resourceSamples.count,
      averageCpuPercent: Self.average(cpuPercents), peakCpuPercent: cpuPercents.max(),
      thermalEvents: inputs.thermalEvents,
      baselineBefore: inputs.baselineBefore,
      baselineAfter: inputs.baselineAfter, report: inputs.report)
  }

  static func rate(count: Int, overSeconds seconds: Double) -> Double {
    guard seconds > 0 else { return 0 }
    return Double(count) / seconds
  }

  static func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
}
