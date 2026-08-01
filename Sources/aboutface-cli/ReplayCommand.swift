import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli replay <path>` — the §14 corpus-harness half of Phase 1's
/// "test corpus harness. Emits `FrameAnalysis` to console" acceptance
/// criterion. Feeds a `FileCaptureSource` through `AnalysisEngine` and
/// prints one line per frame, then a summary.
struct Replay: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "replay",
    abstract:
      "Replay a video file through AnalysisEngine and print FrameAnalysis, one line per frame.",
    discussion: """
      Plain-text output (default): one line per frame, space-separated fields in this fixed order:

        <timestampSeconds> <signalState> faces=<faceCount> err=<x>,<y> dist=<distanceError> \
      dz=<inDeadZone> ypr=<yaw>,<pitch>,<roll> luma=<faceLuma>,<backgroundLuma> conf=<confidence>

      Fields that depend on a detected face (err, dist, dz, ypr, conf) print "-" on a frame with \
      no face. After the last frame, a blank line, then a summary block: total frame count, a \
      signalState histogram, and the mean of |error.x| / |error.y| over frames that had a face.

      Pass --json for one JSON object per line instead (same fields; explicit null instead of "-"; \
      every key present on every line regardless of signalState). Key ORDER is not part of the \
      contract -- look fields up by name. No summary block is printed after JSON output, so a \
      script can pipe stdout straight into a JSON-lines parser without special-casing a trailing \
      non-JSON block.
      """
  )

  @Argument(help: "Path to a video file (any AVFoundation-readable container/codec).")
  var path: String

  @Flag(
    help: ArgumentHelp(
      "Simulate a mirrored capture by flipping the clip's pixels before analysis "
        + "(§3.4 mirror-convention acceptance testing)."
    )
  )
  var simulateMirrored = false

  @Flag(help: "Pace frame delivery at the clip's real-time rate instead of as fast as possible.")
  var paced = false

  @Flag(help: "Emit one JSON object per line instead of the plain-text format.")
  var json = false

  func run() async throws {
    let url = URL(fileURLWithPath: path)
    let pacing: FileCaptureSource.PacingMode = paced ? .realTime : .unpaced
    let source = FileCaptureSource(url: url, pacing: pacing, simulateMirrored: simulateMirrored)
    let engine = AnalysisEngine(backend: VisionBackend())

    try await source.start()

    var frameCount = 0
    var stateHistogram: [String: Int] = [:]
    var absErrorXSum: Float = 0
    var absErrorYSum: Float = 0
    var errorSampleCount = 0

    for try await output in engine.stream(from: source) {
      frameCount += 1
      let line = OutputLine(output)
      stateHistogram[line.signalState, default: 0] += 1
      if let framing = output.framing {
        absErrorXSum += abs(framing.error.x)
        absErrorYSum += abs(framing.error.y)
        errorSampleCount += 1
      }
      print(json ? line.jsonString() : line.plainText())
    }

    await source.stop()

    guard !json else { return }
    printSummary(
      frameCount: frameCount,
      stateHistogram: stateHistogram,
      absErrorXSum: absErrorXSum,
      absErrorYSum: absErrorYSum,
      errorSampleCount: errorSampleCount
    )
  }

  private func printSummary(
    frameCount: Int,
    stateHistogram: [String: Int],
    absErrorXSum: Float,
    absErrorYSum: Float,
    errorSampleCount: Int
  ) {
    print("")
    print("frames=\(frameCount)")
    for (state, count) in stateHistogram.sorted(by: { $0.key < $1.key }) {
      print("  \(state)=\(count)")
    }
    if errorSampleCount > 0 {
      let meanAbsX = absErrorXSum / Float(errorSampleCount)
      let meanAbsY = absErrorYSum / Float(errorSampleCount)
      print(
        "meanAbsError x=\(String(format: "%.4f", meanAbsX)) y=\(String(format: "%.4f", meanAbsY)) "
          + "(over \(errorSampleCount) frames with a detected face)")
    } else {
      print("meanAbsError: no frames with a detected face")
    }
  }
}
