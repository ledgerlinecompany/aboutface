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

  /// Field finding (2026-08-05): the first measurement of Center Stage's
  /// effect on face detection was invalid because opening the session is what
  /// activates a Continuity Camera, and the maintainer had to physically
  /// reposition the phone once it woke — inside the measurement window. Two
  /// multi-second "face lost" episodes got recorded that were a person moving
  /// a camera, not the behavior under test. Any live measurement whose
  /// subject is also the person operating the rig needs settling time that is
  /// not counted, and asking them to be ready BEFORE the session opens is
  /// impossible when opening the session is what wakes the hardware.
  @Option(
    help:
      "Seconds to analyze but exclude from stats, letting the camera wake and the subject settle."
  )
  var warmup: Double = 0

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
    let centerStageAfter = Self.centerStageDescription(device)
    await source.stop()

    printSummary(result)
    print("centerStageAtEnd: \(centerStageAfter)")
  }

  /// §12.5's reading for the device under test, so a run LABELS ITS OWN
  /// CONDITION instead of relying on someone remembering which way a toggle
  /// was set. Two measurement sessions were invalidated on 2026-08-05 by
  /// exactly that ambiguity — a Continuity Camera slept and silently reset
  /// Center Stage between runs, and a locked phone changed what was being
  /// captured — after which the numbers were untrustworthy in a way no
  /// amount of care at the keyboard could have caught. Printed at the END of
  /// the run, while the session is still the thing that was just measured.
  ///
  /// `.deviceNotFound` prints as itself, never as "off": the same rule
  /// `CenterStageDeviceReading` exists to enforce (§12.5).
  private static func centerStageDescription(_ uniqueID: String?) -> String {
    guard let uniqueID else {
      return "not read (no --device given; pass one to label the run's Center Stage condition)"
    }
    switch CenterStageReader.read(forUniqueID: uniqueID) {
    case .found(let reading):
      return reading.automaticFramingInEffect ? "ACTIVE (framing is automatic)" : "not active"
    case .deviceNotFound:
      return "could not read -- device not found"
    }
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
    /// EVERY frame's `signalState`, tallied — not the once-per-second sample
    /// the `t=Ns` status lines print. §12.5 field finding (2026-08-05): the
    /// maintainer reported the §7.3 face-lost/reacquired earcons firing
    /// repeatedly under Center Stage, and a 1 Hz sample cannot see a dropout
    /// shorter than a second, while §7.3's rung 1 fires at 500ms in Setup.
    /// The instrument could not answer the question it was being asked, which
    /// is its own kind of silent failure.
    let stateCounts: [SignalState: Int]
    /// Runs of consecutive frames where no face was available at all
    /// (`.noFace`/`.noSignal`) — the states §7.3's ladder actually escalates
    /// on. Count and worst-case duration, so "loses the face often" becomes a
    /// number instead of an impression.
    let faceLostEpisodes: Int
    let longestFaceLostMs: Int
    let totalFaceLostMs: Int
    /// Every DISTINCT pixel dimension observed across the whole run, in the
    /// order first seen. More than one entry means the delivered format
    /// changed mid-stream — which `AVCaptureDevice.h` says Center Stage can
    /// force (it restricts the device's zoom and frame-rate ranges while
    /// active). Nothing in this app previously read the format back after the
    /// first frame; that "latch it once" assumption is exactly the shape of
    /// the bug PR #57 fixed, so this instrument no longer makes it.
    let observedDimensions: [PixelDimensions]
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
  ///
  /// ## The watchdog is load-bearing, not belt-and-braces
  ///
  /// The deadline check lives INSIDE the `for try await` loop, so it is only
  /// ever evaluated when a frame arrives. A camera that opens successfully
  /// but then delivers NOTHING therefore hangs this command forever, with no
  /// output and no error — which is exactly what happened while verifying
  /// Monitor's 640×480 format (a camera left wedged by two clients
  /// contending for it, a state macOS recovers from only after the
  /// contending processes are gone). "Hangs silently and indefinitely" is
  /// the worst possible failure mode for the §13 Phase 4 acceptance
  /// instrument, whose whole job is being run unattended for 30 minutes and
  /// believed afterward.
  ///
  /// `stop()`ing the source is what finishes `source.frames`, which is what
  /// lets the `for try await` below exit — so the watchdog stops the source
  /// rather than trying to cancel a loop that is not suspended at a
  /// cancellation point. The grace period past `deadline` exists so the
  /// watchdog can never pre-empt a healthy run that is merely a few frames
  /// from its own clean exit.
  private func runLoop(
    engine: AnalysisEngine,
    source: CameraCaptureSource
  ) async -> RunResult {
    let clock = ContinuousClock()
    let runStart = clock.now
    // Statistics start AFTER the warmup window — see `warmup`'s doc comment
    // for the invalid measurement that motivated it. `start` is the point
    // every reported number is measured from, so achieved fps, the state
    // tally, and face-lost episodes all describe the settled window only.
    let start = runStart.advanced(by: .seconds(warmup))
    let deadline = start.advanced(by: .seconds(seconds))
    var announcedMeasuring = warmup <= 0
    if warmup > 0 {
      print("warmup: \(String(format: "%.0f", warmup))s -- settle now, not yet measuring")
    }

    var lastReportedSecond = -1
    // Per-frame accumulation lives in `LiveRunStats` (its own file) — see
    // that type's doc comment for why a once-per-second sample could not
    // answer the question §12.5 needed answered.
    var stats = LiveRunStats()

    let watchdog = Task {
      try await Task.sleep(
        until: deadline.advanced(by: .seconds(Self.watchdogGraceSeconds)), clock: .continuous)
      await source.stop()
    }
    defer { watchdog.cancel() }

    do {
      for try await output in engine.stream(from: source) {
        // Warmup frames are analyzed (so the pipeline and the camera's own
        // exposure/tracking are fully warm when measurement begins) but
        // contribute to nothing that gets reported.
        guard clock.now >= start else { continue }
        if !announcedMeasuring {
          announcedMeasuring = true
          print("measuring now for \(seconds)s -- hold position")
        }
        stats.record(output, at: clock.now)

        let elapsed = clock.now - start
        let elapsedWholeSeconds = Int(elapsed.components.seconds)
        if elapsedWholeSeconds != lastReportedSecond {
          lastReportedSecond = elapsedWholeSeconds
          print(
            "t=\(elapsedWholeSeconds)s frames=\(stats.frameCount) "
              + "state=\(output.analysis.signalState) faces=\(output.analysis.faceCount)")
        }
        if clock.now >= deadline {
          break
        }
      }
    } catch {
      print("Live analysis stopped early due to an error: \(error)")
    }

    stats.finish(at: clock.now)

    return RunResult(
      frameCount: stats.frameCount, elapsedSeconds: Self.seconds(clock.now - start),
      actualDimensions: stats.firstDimensions, stateCounts: stats.stateCounts,
      faceLostEpisodes: stats.faceLostEpisodes, longestFaceLostMs: stats.longestFaceLostMs,
      totalFaceLostMs: stats.totalFaceLostMs, observedDimensions: stats.observedDimensions)
  }

  /// `Duration.components` gives whole seconds plus attoseconds, not a
  /// `Double` directly; converts to fractional seconds for the achieved-fps
  /// math below, floored away from exact 0 to avoid a division by zero if
  /// the loop above exits on its very first iteration (e.g. an immediate
  /// backend error).
  /// How long past `--seconds` the watchdog in `runLoop(engine:source:)`
  /// waits before force-stopping the source. Generous on purpose: this is a
  /// stuck-camera backstop, not a frame-rate assertion, and pre-empting a
  /// healthy-but-slow run would turn a good measurement into a confusing
  /// one. Not a `Config` field (§0/§11) because it is a property of this
  /// diagnostic harness, not of the shipping feedback behavior.
  private static let watchdogGraceSeconds = 5.0

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
    printSignalBreakdown(result)
  }

  /// The per-FRAME truth the once-per-second `t=Ns` lines above cannot show —
  /// see `RunResult.stateCounts`'s doc comment for the §12.5 field finding
  /// that motivated it. Split from `printSummary` to stay under SwiftLint's
  /// `function_body_length` limit, same as `ProbeCameraCommand`'s own
  /// per-topic print helpers.
  private func printSignalBreakdown(_ result: RunResult) {
    let total = max(1, result.frameCount)
    let order: [SignalState] = [.ok, .lowConfidence, .noFace, .noSignal]
    let counts = order.map { state -> String in
      let count = result.stateCounts[state] ?? 0
      let percent = Double(count) * 100 / Double(total)
      return "\(state)=\(count) (\(String(format: "%.1f", percent))%)"
    }
    print("signalStates, every frame: " + counts.joined(separator: " "))
    print(
      "faceLostEpisodes=\(result.faceLostEpisodes) "
        + "longestFaceLostMs=\(result.longestFaceLostMs) "
        + "totalFaceLostMs=\(result.totalFaceLostMs) "
        + "(episodes are runs of noFace/noSignal -- what §7.3's ladder escalates on)")

    // More than one distinct set means the delivered format changed
    // mid-stream. Printed as a plain fact either way, never silently, since
    // "we only ever looked at the first frame" is what PR #57's bug was.
    if result.observedDimensions.count > 1 {
      let described = result.observedDimensions.map { "\($0.width)x\($0.height)" }
      print(
        "WARNING: delivered format CHANGED mid-stream: "
          + described.joined(separator: " then ")
          + " -- see §12.5 (Center Stage restricts the device's zoom and frame-rate ranges).")
    } else {
      print("deliveredFormatStableAcrossRun=yes")
    }
  }

}
