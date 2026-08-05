import AboutFaceCore

/// The `acceptance` command's per-frame ingest loop plus its watchdog —
/// split out of `AcceptanceCommand.swift` purely for file-length/complexity
/// budget, same precedent every other `+File.swift` split in this codebase
/// cites. Everything here is still `Acceptance`'s own implementation.
///
/// ## The watchdog is load-bearing, not belt-and-braces
///
/// `LiveCommand`'s own watchdog doc comment tells the story this design
/// extends: a camera left wedged by contending clients delivers NOTHING for
/// the rest of a run, with no error and no output, which is the worst
/// failure mode for an instrument whose whole job is running unattended and
/// being believed afterward. `LiveCommand`'s watchdog only guards the
/// OVERALL deadline (fine for a run measured in tens of seconds); a 30–45
/// minute acceptance session that stalls at minute 5 must not sit silent
/// for the other 25+ minutes before anyone notices — `frameStallTimeoutSeconds`
/// below detects a stall independent of how much of the run remains, and
/// records WHY the loop stopped early so the summary can say so loudly
/// (PR brief) instead of just quietly running short.
struct AcceptanceRunLoopOptions: Sendable {
  var targetAnalysisHz: Double?
  var deadline: ContinuousClock.Instant
  var frameStallTimeoutSeconds: Double
  var watchdogGraceSeconds: Double
  var watchdogCheckIntervalSeconds: Double
}

struct AcceptanceRunLoopResult: Sendable {
  var stats: LiveRunStats
  var rawFrameCount: Int
  var achievedRawCaptureFps: Double?
  var completedFullDuration: Bool
  var terminationReason: String?
  var actualElapsedSeconds: Double
}

/// Tracks the wall-clock instant of the most recently received frame, so
/// the watchdog `Task` (a different task than the one running the ingest
/// loop) can detect a stall without racing the loop's own state.
actor AcceptanceFrameLiveness {
  private var lastFrameInstant: ContinuousClock.Instant

  init(start: ContinuousClock.Instant) {
    lastFrameInstant = start
  }

  func touch(_ now: ContinuousClock.Instant) {
    lastFrameInstant = now
  }

  func secondsSinceLastFrame(now: ContinuousClock.Instant) -> Double {
    AcceptanceElapsed.seconds(from: lastFrameInstant, to: now)
  }
}

/// First-write-wins record of WHY the run stopped early, if it did. Read by
/// the main loop after it exits to decide `completedFullDuration` and
/// `terminationReason` — written only by the watchdog `Task` (a thrown
/// stream error is tracked separately, directly in the loop, since that
/// case does not need cross-task coordination).
actor AcceptanceTerminationFlag {
  private var reason: String?

  func recordIfUnset(_ newReason: String) {
    if reason == nil { reason = newReason }
  }

  func current() -> String? { reason }
}

/// `AcceptanceRunLoop.run`'s collaborators, bundled — purely to stay within
/// SwiftLint's `function_parameter_count` limit, which CI enforces as an
/// ERROR (`swiftlint --strict` promotes every warning), not merely as advice.
/// Same precedent as `CameraFormatProbe.CaptureRequest`, which bundles
/// `captureOneFrame`'s inputs for the identical reason; like that type this
/// is not otherwise meaningful as a standalone value.
struct AcceptanceRunLoopInputs {
  let engine: AnalysisEngine
  let source: AcceptanceCountingCaptureSource
  let rawCounter: RawFrameArrivalCounter
  let router: FeedbackRouter
  let start: ContinuousClock.Instant
}

enum AcceptanceRunLoop {
  static func run(
    inputs: AcceptanceRunLoopInputs,
    options: AcceptanceRunLoopOptions
  ) async -> AcceptanceRunLoopResult {
    let engine = inputs.engine
    let source = inputs.source
    let router = inputs.router
    let start = inputs.start
    let liveness = AcceptanceFrameLiveness(start: start)
    let terminationFlag = AcceptanceTerminationFlag()

    let watchdog = Task {
      await watchdogLoop(
        source: source, liveness: liveness, terminationFlag: terminationFlag, options: options)
    }

    var stats = LiveRunStats()
    var reachedDeadlineNormally = false
    var loopErrorReason: String?
    let clock = ContinuousClock()

    let analyzedFrames = engine.stream(from: source, targetAnalysisHz: options.targetAnalysisHz)
    do {
      for try await output in analyzedFrames {
        let now = clock.now
        await liveness.touch(now)
        stats.record(output, at: now)
        await router.ingest(output, at: now)
        if now >= options.deadline {
          reachedDeadlineNormally = true
          await source.stop()
          break
        }
      }
    } catch {
      loopErrorReason = "capture stopped with an error: \(error)"
    }

    watchdog.cancel()
    await source.stop()
    stats.finish(at: clock.now)

    let watchdogReason = await terminationFlag.current()
    let completedFullDuration =
      reachedDeadlineNormally && loopErrorReason == nil && watchdogReason == nil
    let rawSnapshot = await inputs.rawCounter.snapshot()

    return AcceptanceRunLoopResult(
      stats: stats, rawFrameCount: rawSnapshot.count,
      achievedRawCaptureFps: rawSnapshot.achievedFps,
      completedFullDuration: completedFullDuration,
      terminationReason: loopErrorReason ?? watchdogReason,
      actualElapsedSeconds: AcceptanceElapsed.seconds(from: start, to: clock.now))
  }

  private static func watchdogLoop(
    source: AcceptanceCountingCaptureSource, liveness: AcceptanceFrameLiveness,
    terminationFlag: AcceptanceTerminationFlag, options: AcceptanceRunLoopOptions
  ) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(
          for: .seconds(options.watchdogCheckIntervalSeconds), clock: .continuous)
      } catch {
        return
      }
      let now = ContinuousClock.now
      if now >= options.deadline.advanced(by: .seconds(options.watchdogGraceSeconds)) {
        await terminationFlag.recordIfUnset(
          "watchdog: the overall deadline plus a \(options.watchdogGraceSeconds)s grace period "
            + "elapsed without the capture loop exiting on its own -- forced stop.")
        await source.stop()
        return
      }
      let sinceLastFrame = await liveness.secondsSinceLastFrame(now: now)
      if sinceLastFrame >= options.frameStallTimeoutSeconds {
        await terminationFlag.recordIfUnset(
          "watchdog: no frames received for \(Int(sinceLastFrame))s (timeout "
            + "\(Int(options.frameStallTimeoutSeconds))s) -- the camera appears stalled -- "
            + "forced stop.")
        await source.stop()
        return
      }
    }
  }
}
