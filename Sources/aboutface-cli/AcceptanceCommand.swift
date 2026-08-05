import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli acceptance` — the instrument §13 Phase 4's acceptance
/// criterion has never had: "a 30-minute session with the user leaving the
/// desk for 10 minutes produces the correct escalate-then-stop-then-recover
/// sequence and nothing else; CPU and thermal impact measured and
/// documented." Runs the real Monitor-mode pipeline, wired the way
/// `PipelineModel` wires the live app (`App/Models/PipelineModel+Session
/// .swift`/`+Audio.swift` are the reference; `replay --audio` is the
/// precedent for a CLI command driving the real renderers instead of a
/// lookalike) — real camera, real `AudioRenderer`/`SpeechRenderer`, real
/// `FeedbackRouter(mode: .monitor)`, `Config.camera.monitor`'s capture
/// format, and `AnalysisRateDecimator` via `AnalysisEngine.stream(from:
/// targetAnalysisHz:)` — for a configurable duration, recording everything
/// `AcceptanceEvaluator` needs to judge afterward.
///
/// §7.3's rung-3 STOP fires no sound: `FeedbackRouter.isUserLikelyAway()`'s
/// doc comment names polling as its intended observer, so
/// `AcceptanceAwayPoller` does exactly that at `--away-poll-interval-seconds`
/// (~1Hz default). See `AcceptanceEventRecorder`/`AcceptanceSpeechRecorder`
/// for the other two channels, `AcceptanceResourceSampler` for CPU/thermal,
/// `AcceptanceCountingCaptureSource` for the raw-vs-analyzed frame rate
/// distinction issue #67 needs, `AcceptanceRunLoop` for the ingest loop and
/// its stall watchdog, and `AcceptanceCommand+Artifact.swift` for the
/// `--json` writer.
///
/// Does NOT run this against a live camera in CI or as part of this PR's
/// own verification — the maintainer runs it. `swift test` covers only the
/// pure `AcceptanceEvaluator` (`AcceptanceEvaluatorTests.swift`) against
/// hand-built event sequences.
struct Acceptance: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "acceptance",
    abstract:
      "Run the real Monitor-mode pipeline for a fixed duration, recording the §7.3 face-lost "
      + "escalation ladder and CPU/thermal impact, for §13 Phase 4's acceptance criterion.",
    discussion: """
      Wires the exact renderer/router types PipelineModel uses in the live app -- \
      AudioRenderer + SpeechRenderer + FeedbackRouter(mode: .monitor) -- against a real camera, \
      using Config.camera.monitor's capture format and analysisHz (AnalysisRateDecimator), so \
      this exercises Monitor mode as shipped, not a simulation.

      Prints "RECORDING STARTED" clearly at the top so you know when it is safe to leave the \
      desk, then runs silently (aside from very occasional status lines) for --minutes. At the \
      end it prints a plain-text, one-fact-per-line report (no tables -- this is read in \
      Terminal with VoiceOver) covering: requested vs. achieved capture and analysis frame \
      rates (folding in issue #67 -- Continuity Camera can silently ignore a 15fps request and \
      deliver 30), the §7.3 ladder's four rungs (matched/missing/off-schedule, with exact \
      timestamps), everything else that fired (the "and nothing else" clause), and CPU/thermal \
      numbers. A run that stops before --minutes elapses -- a capture error, or the watchdog \
      detecting a stalled camera -- prints a loud banner ahead of the rest of the report and \
      says so in the JSON artifact too, rather than a summary that looks complete.

      Also appends one session record to --json (default acceptance-session-log.json in the \
      current directory), following TrialSessionLog's own accumulate-into-one-file precedent, \
      so successive runs (different tuning profiles, different days) stay comparable.
      """
  )

  @Option(help: "How long to run the session, in minutes.")
  var minutes: Double = 30

  /// Defaults to ON, unlike `record-corpus --speak`'s opt-in, because the
  /// failure it prevents is asymmetric: this command's whole purpose is that
  /// the maintainer starts it and leaves the room, and a printed banner only
  /// reaches a blind user whose VoiceOver focus happens to be on the terminal
  /// at that exact instant. Missing the cue silently costs the entire run.
  /// `--no-speak` is there for a run being recorded for audio analysis, where
  /// any extra utterance would contaminate the recording.
  @Flag(
    inversion: .prefixedNo,
    help: ArgumentHelp(
      "Speak the start and finish cues aloud, so you can leave the desk without watching the "
        + "terminal."))
  var speak = true

  @Option(
    help:
      "AVCaptureDevice.uniqueID of the camera to open. Defaults to the system default video device."
  )
  var device: String?

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile (Debug panel Export…) to run this "
        + "session against, instead of Config.defaults."))
  var configPath: String?

  @Option(help: "Path to append this session's JSON record to.")
  var json: String = "acceptance-session-log.json"

  @Option(
    name: .customLong("away-poll-interval-seconds"),
    help: "How often to poll FeedbackRouter.isUserLikelyAway() (§7.3 rung 3 fires no sound).")
  var awayPollIntervalSeconds: Double = 1.0

  @Option(
    name: .customLong("resource-sample-interval-seconds"),
    help: "How often to sample CPU usage and thermal state.")
  var resourceSampleIntervalSeconds: Double = 5.0

  @Option(
    name: .customLong("frame-stall-timeout-seconds"),
    help: ArgumentHelp(
      "If no frame arrives for this long, the watchdog treats the camera as stalled and stops "
        + "the run early rather than hanging silently for the rest of --minutes."))
  var frameStallTimeoutSeconds: Double = 90.0

  @Option(
    name: .customLong("rung-tolerance-ms"),
    help: ArgumentHelp(
      "Override AcceptanceEvaluator's timing tolerance (milliseconds) around each §7.3 rung's "
        + "expected elapsed time. Defaults to a value derived from Config (§7.2's N-frame "
        + "confirmation latency at Monitor's analysis rate) -- see AcceptanceTolerances.derived."
    ))
  var rungToleranceMs: Int?

  func run() async throws {
    let config = try AudioCLISupport.loadConfig(configPath: configPath)
    let modeSettings = config.camera.monitor
    let pipeline = try await openPipeline(config: config)

    let awayPoller = AcceptanceAwayPoller(
      router: pipeline.router, recorder: pipeline.recorder,
      pollIntervalSeconds: awayPollIntervalSeconds)
    let awayTask = Task { await awayPoller.run() }
    let resourceTask = Task {
      await Self.sampleResourcesPeriodically(
        sampler: pipeline.resourceSampler, intervalSeconds: resourceSampleIntervalSeconds)
    }

    await announceRecordingStarted()

    let deadline = pipeline.start.advanced(by: .seconds(minutes * 60))
    let options = AcceptanceRunLoopOptions(
      targetAnalysisHz: modeSettings.analysisHz, deadline: deadline,
      frameStallTimeoutSeconds: frameStallTimeoutSeconds, watchdogGraceSeconds: 30,
      watchdogCheckIntervalSeconds: 5)
    let loopResult = await AcceptanceRunLoop.run(
      inputs: AcceptanceRunLoopInputs(
        engine: pipeline.engine, source: pipeline.source, rawCounter: pipeline.rawCounter,
        router: pipeline.router, start: pipeline.start),
      options: options)

    awayTask.cancel()
    resourceTask.cancel()
    await pipeline.audio.stop()

    let events = await pipeline.recorder.snapshot()
    let resourceSnapshot = await pipeline.resourceSampler.snapshot()
    let report = evaluateReport(config: config, events: events)
    let summaryData = makeSummaryData(
      modeSettings: modeSettings, loopResult: loopResult, resourceSnapshot: resourceSnapshot,
      report: report)

    // Spoken BEFORE the report prints, not after: the report is long, and
    // the cue's job is to tell him the session is over and worth coming back
    // to — not to narrate the end of stdout.
    await speakSessionCue(
      loopResult.completedFullDuration
        ? "Recording complete. The report is ready."
        : "Recording stopped early. The report explains why.")

    AcceptanceSummary.print(summaryData)
    try writeArtifact(summaryData: summaryData, config: config)

    if !loopResult.completedFullDuration {
      throw ExitCode.failure
    }
  }

  // MARK: - Wiring (§13's "wire it the way PipelineModel wires the real app")

  /// Everything the run loop needs, opened and started. A `struct` bundle
  /// rather than a handful of separate `let`s at the `run()` call site,
  /// purely so `run()` itself stays short enough to read as "open the
  /// pipeline, run the loop, report" rather than an unbroken wall of setup.
  private struct Pipeline {
    let engine: AnalysisEngine
    let source: AcceptanceCountingCaptureSource
    let rawCounter: RawFrameArrivalCounter
    let audio: AudioRenderer
    let router: FeedbackRouter
    let recorder: AcceptanceEventRecorder
    let resourceSampler: AcceptanceResourceSampler
    let start: ContinuousClock.Instant
  }

  /// Opens the camera, starts real audio, and wires
  /// `FeedbackRouter(mode: .monitor)` exactly the way `PipelineModel
  /// .startFeedbackChain()` (`App/Models/PipelineModel+Audio.swift`) wires
  /// the live app's Monitor mode. Throws `ExitCode.failure` (after printing
  /// a clear, non-crashing message) on any failure — no partial pipeline is
  /// ever handed back to `run()`.
  private func openPipeline(config: Config) async throws -> Pipeline {
    guard let cameraSource = makeCameraSource(config: config) else {
      Swift.print(
        "No camera available: no default video device was found (e.g. headless CI/no hardware).")
      throw ExitCode.failure
    }

    let rawCounter = RawFrameArrivalCounter()
    let countingSource = AcceptanceCountingCaptureSource(
      wrapping: cameraSource, counter: rawCounter)
    let engine = AnalysisEngine(backend: VisionBackend(), config: config)

    do {
      try await countingSource.start()
    } catch {
      Swift.print(
        "Could not start capture: \(error). If this is a permission problem, grant camera "
          + "access in System Settings > Privacy & Security > Camera and try again.")
      throw ExitCode.failure
    }

    let audio = AudioRenderer(config: config.audio, mode: .realtime)
    do {
      try await audio.start()
    } catch {
      Swift.print("\(AudioCLISupport.AudioUnavailable(underlying: error))")
      await countingSource.stop()
      throw ExitCode.failure
    }

    let start = ContinuousClock.now
    let recorder = AcceptanceEventRecorder(start: start)
    let speech = SpeechRenderer(config: config.speech)
    let speechRecorder = AcceptanceSpeechRecorder(wrapping: speech, recorder: recorder)
    let router = FeedbackRouter(
      audio: audio, speech: speechRecorder, config: config, mode: .monitor)
    await router.addEventSubscriber(recorder)

    return Pipeline(
      engine: engine, source: countingSource, rawCounter: rawCounter, audio: audio, router: router,
      recorder: recorder, resourceSampler: AcceptanceResourceSampler(start: start), start: start)
  }

  private func makeCameraSource(config: Config) -> CameraCaptureSource? {
    let modeSettings = config.camera.monitor
    if let device {
      return CameraCaptureSource(
        deviceUniqueID: device, width: modeSettings.width, height: modeSettings.height,
        frameRate: modeSettings.frameRate)
    }
    return CameraCaptureSource.defaultDevice(
      width: modeSettings.width, height: modeSettings.height, frameRate: modeSettings.frameRate)
  }

  /// "Announce clearly when recording starts, so the maintainer knows when
  /// to leave" — as a terminal banner AND, unless `--no-speak`, aloud.
  private func announceRecordingStarted() async {
    Swift.print(String(repeating: "=", count: 78))
    Swift.print("RECORDING STARTED -- you may leave the desk now.")
    Swift.print("Session will run for \(minutes) minutes.")
    Swift.print(String(repeating: "=", count: 78))
    await speakSessionCue("Recording started. You may leave the desk now.")
  }

  /// Speaks a session cue aloud, unless `--no-speak`.
  ///
  /// A printed banner alone is not sufficient here, for a specific reason
  /// rather than general politeness: the maintainer is blind, and the entire
  /// point of this instrument is that he STARTS it and WALKS AWAY. A line of
  /// terminal output only reaches him if VoiceOver focus happens to be
  /// parked on the terminal at the exact moment it prints — which is
  /// precisely when he is getting out of the chair. Missing it costs a
  /// 30-minute run, and he would not find out until the report came back
  /// wrong.
  ///
  /// Follows `record-corpus --speak`'s precedent exactly, reusing that
  /// command's own `Speech` type: deliberately NOT `Lexicon`'s closed spoken
  /// vocabulary (§6.3), because the audience is a human operating a session
  /// harness, not an end user hearing live framing feedback — the same
  /// distinction `CorpusSpeech.swift`'s own doc comment draws.
  /// `Lexicon.Phrase.init` is `private` besides, so no product phrase can be
  /// fabricated here even by accident; the type system already enforces
  /// which register this belongs to.
  ///
  /// Fires only at the start and end of a run, never during it, so it cannot
  /// overlap or mask the feedback audio the session exists to observe. It
  /// also never passes through `FeedbackRouter`, so it is invisible to the
  /// recorder and can never turn up in the report as if it were product
  /// speech.
  private func speakSessionCue(_ text: String) async {
    guard speak else { return }
    await Speech().speak(text)
  }

  private static func sampleResourcesPeriodically(
    sampler: AcceptanceResourceSampler, intervalSeconds: Double
  ) async {
    while !Task.isCancelled {
      await sampler.sampleOnce()
      do {
        try await Task.sleep(for: .seconds(intervalSeconds))
      } catch {
        return
      }
    }
  }

  // MARK: - Report assembly

  private func evaluateReport(config: Config, events: [AcceptanceEvent]) -> AcceptanceReport {
    let awayPollIntervalMs = Int(awayPollIntervalSeconds * 1000)
    let tolerances =
      rungToleranceMs.map {
        AcceptanceTolerances(rungTimingToleranceMs: $0, awayPollIntervalMs: awayPollIntervalMs)
      }
      ?? AcceptanceTolerances.derived(from: config, awayPollIntervalMs: awayPollIntervalMs)
    return AcceptanceEvaluator.evaluate(
      AcceptanceEvaluator.Input(
        events: events, feedbackConfig: config.feedback, mode: .monitor, tolerances: tolerances))
  }

  private func makeSummaryData(
    modeSettings: CameraModeCaptureSettings, loopResult: AcceptanceRunLoopResult,
    resourceSnapshot: (
      samples: [AcceptanceResourceSample], thermalEvents: [AcceptanceThermalEvent]
    ),
    report: AcceptanceReport
  ) -> AcceptanceSummary.Data {
    let cpuPercents = resourceSnapshot.samples.map(\.cpuPercent)
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
      resourceSampleCount: resourceSnapshot.samples.count,
      averageCpuPercent: Self.average(cpuPercents), peakCpuPercent: cpuPercents.max(),
      thermalEvents: resourceSnapshot.thermalEvents, report: report)
  }

  private static func rate(count: Int, overSeconds seconds: Double) -> Double {
    guard seconds > 0 else { return 0 }
    return Double(count) / seconds
  }

  private static func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
}
