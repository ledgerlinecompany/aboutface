import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli live` — the §13 Phase 1 acceptance probe for "runs a live
/// camera at 30Hz without dropping frames." Runs a `CameraCaptureSource`
/// through `AnalysisEngine` for a fixed duration, printing a 1 Hz status
/// line, then a summary comparing achieved analysis rate to the requested
/// capture rate.
///
/// This is a harness for a human at a terminal, not a scripting target the
/// way `replay` is — there is no `--json`, since a live run's value is
/// mainly the printed achieved-fps/dropped-frames numbers a person reads
/// once at the end.
struct Live: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "live",
    abstract: "Run AnalysisEngine against a live camera for a fixed duration, printing 1 Hz "
      + "status lines and a final achieved-fps / dropped-frames summary.",
    discussion: """
      Requests the camera at --width x --height @ --fps explicitly (§5.1: "requested explicitly, \
      not negotiated"), runs for --seconds, then prints:

        achievedFps=<framesProcessed / secondsElapsed>
        droppedFramesEstimate=<requestedFps * secondsElapsed - framesProcessed>
        actualWidth=<...> actualHeight=<...> requestedWidth=<...> requestedHeight=<...>

      "Dropped" here is an estimate relative to the requested rate, not a count of frames the \
      capture layer is known to have discarded — this harness has no lower-level visibility into \
      AVFoundation's own drop accounting. A near-zero estimate at a requested 30fps is the §13 \
      Phase 1 acceptance signal ("runs a live camera at 30Hz without dropping frames").

      The actual/requested width and height are two SEPARATE readings, not one derived from the \
      other (PR #53: a requested format can silently fail to take effect on macOS) — actual is \
      read directly off the first delivered frame's pixel buffer \
      (CapturedFrame.pixelDimensions), requested is echoed back from --width/--height verbatim. \
      Printing differently is the mismatch signal this line exists to catch; this harness does \
      not compare them for you or editorialize about it.

      If no camera is available, or the user has not granted camera permission, this prints a \
      clear message and exits with a non-zero status rather than crashing.
      """
  )

  @Option(
    help:
      "AVCaptureDevice.uniqueID of the camera to open. Defaults to the system default video device."
  )
  var device: String?

  @Option(help: "Requested capture width in pixels.")
  var width = 1280

  @Option(help: "Requested capture height in pixels.")
  var height = 720

  @Option(help: "Requested capture frame rate in fps.")
  var fps: Double = 30

  @Option(help: "How many seconds to run before printing the summary and exiting.")
  var seconds = 10

  func run() async throws {
    guard let source = makeSource() else {
      print(
        "No camera available: no default video device was found (e.g. headless CI/no hardware).")
      throw ExitCode.failure
    }

    let engine = AnalysisEngine(backend: VisionBackend())

    do {
      try await source.start()
    } catch {
      print(
        "Could not start capture: \(error). If this is a permission problem, grant camera access "
          + "in System Settings > Privacy & Security > Camera and try again.")
      throw ExitCode.failure
    }

    let result = await runLoop(engine: engine, source: source)
    await source.stop()

    printSummary(result)
  }

  /// `runLoop(engine:source:)`'s return value — a named struct rather than a
  /// 3-member tuple purely to stay within SwiftLint's `large_tuple` limit
  /// (2 members), same reasoning as `Tests/AboutFaceCoreTests`' `TestRGB`/
  /// `Dimensions` helper types (see `AnalysisEngineTestSupport.swift`/
  /// `CaptureSourceTests.swift`).
  private struct RunResult {
    let frameCount: Int
    let elapsedSeconds: Double
    let actualDimensions: PixelDimensions?
  }

  private func makeSource() -> CameraCaptureSource? {
    if let device {
      return CameraCaptureSource(
        deviceUniqueID: device, width: width, height: height, frameRate: fps)
    }
    return CameraCaptureSource.defaultDevice(width: width, height: height, frameRate: fps)
  }

  /// Consumes `engine.stream(from: source)`, printing a status line at most
  /// once per elapsed second, until `seconds` have elapsed. A single
  /// sequential loop (no separate reporting `Task`) so no mutable state is
  /// ever touched from more than one place at once — nothing here needs
  /// Swift 6 strict-concurrency workarounds because there is only one
  /// concurrency domain involved.
  private func runLoop(
    engine: AnalysisEngine,
    source: CameraCaptureSource
  ) async -> RunResult {
    let clock = ContinuousClock()
    let start = clock.now
    let deadline = start.advanced(by: .seconds(seconds))

    var frameCount = 0
    var lastReportedSecond = -1
    // Latched from the FIRST frame that carries one, same "confirm once,
    // don't keep re-reading" shape as `PipelineModel.actualCaptureDimensions`
    // — the format is not expected to change mid-session, so there's
    // nothing more to learn from later frames.
    var actualDimensions: PixelDimensions?

    do {
      for try await output in engine.stream(from: source) {
        frameCount += 1
        if actualDimensions == nil {
          actualDimensions = output.capturedPixelDimensions
        }
        let elapsed = clock.now - start
        let elapsedWholeSeconds = Int(elapsed.components.seconds)
        if elapsedWholeSeconds != lastReportedSecond {
          lastReportedSecond = elapsedWholeSeconds
          print(
            "t=\(elapsedWholeSeconds)s frames=\(frameCount) state=\(output.analysis.signalState) "
              + "faces=\(output.analysis.faceCount)")
        }
        if clock.now >= deadline {
          break
        }
      }
    } catch {
      print("Live analysis stopped early due to an error: \(error)")
    }

    return RunResult(
      frameCount: frameCount, elapsedSeconds: Self.seconds(clock.now - start),
      actualDimensions: actualDimensions)
  }

  /// `Duration.components` gives whole seconds plus attoseconds, not a
  /// `Double` directly; converts to fractional seconds for the achieved-fps
  /// math below, floored away from exact 0 to avoid a division by zero if
  /// the loop above exits on its very first iteration (e.g. an immediate
  /// backend error).
  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    let fractional = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return max(fractional, 0.001)
  }

  private func printSummary(_ result: RunResult) {
    let frameCount = result.frameCount
    let elapsedSeconds = result.elapsedSeconds
    let achievedFps = Double(frameCount) / elapsedSeconds
    let requestedFrames = fps * elapsedSeconds
    let droppedEstimate = max(0, requestedFrames - Double(frameCount))

    print("")
    print(
      "summary: ranSeconds=\(String(format: "%.1f", elapsedSeconds)) framesProcessed=\(frameCount)")
    print(
      "achievedFps=\(String(format: "%.2f", achievedFps)) requestedFps=\(String(format: "%.2f", fps))"
    )
    print(
      "droppedFramesEstimate=\(String(format: "%.1f", droppedEstimate)) "
        + "(requestedFrames=\(String(format: "%.1f", requestedFrames)) - achieved=\(frameCount))")
    // §5.2/PR #53: the requested format is not proof of the delivered one —
    // read directly off the first captured frame's pixel buffer
    // (`CapturedFrame.pixelDimensions`), not echoed from --width/--height.
    // Printed as two independent readings, side by side, so a mismatch is
    // visible from a terminal without opening the app (this is the "checkable
    // headlessly" requirement this line exists to satisfy) — deliberately
    // not compared/flagged here; a human (or a future script) reads both
    // numbers and judges for themselves.
    if let actualDimensions = result.actualDimensions {
      print(
        "actualWidth=\(actualDimensions.width) actualHeight=\(actualDimensions.height) "
          + "requestedWidth=\(width) requestedHeight=\(height)")
    } else {
      print(
        "actualWidth=unknown actualHeight=unknown (no frame was ever received) "
          + "requestedWidth=\(width) requestedHeight=\(height)")
    }
  }
}
