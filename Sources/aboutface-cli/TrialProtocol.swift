import AboutFaceCore
import ArgumentParser
import Foundation

/// `Trial`'s per-session and per-trial protocol implementation — split out
/// of `TrialCommand.swift` purely to keep that file focused on argument
/// parsing, the same reasoning `RecordCorpusPrompts.swift` splits off of
/// `RecordCorpusCommand.swift`. See `TrialContext` (`TrialRuntime.swift`)
/// for the read-only bundle threaded through most functions here.
extension Trial {
  /// Owns the camera/engine/hub lifecycle for the whole session (the
  /// camera runs continuously across all `trials`, never stopped and
  /// restarted between them) and the trial loop. Always stops the audio
  /// engine and the camera before returning, on every exit path.
  func runSession(
    config: Config, source: CameraCaptureSource, chain: AudioCLISupport.FeedbackChain,
    speech: Speech
  ) async throws {
    let engine = AnalysisEngine(backend: VisionBackend(), config: config)
    let hub = TrialHub()
    let pumpTask = Task<Void, Never> {
      await Self.pumpFrames(engine: engine, source: source, hub: hub)
    }
    defer { pumpTask.cancel() }

    let displacementThreshold =
      Float(displacementMultiplier)
      * Float(hypot(config.deadZone.horizontal, config.deadZone.vertical))
    let context = TrialContext(
      hub: hub, chain: chain, speech: speech, displacementThreshold: displacementThreshold,
      deadZone: config.deadZone)
    let sessionLabel =
      label ?? (configPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "defaults")
    let jsonURL = jsonPath.map { URL(fileURLWithPath: $0) }

    var log = jsonURL.map { TrialSessionStore.load(from: $0) } ?? .empty
    var session = makeSessionRecord(
      config: config, label: sessionLabel, displacementThreshold: Double(displacementThreshold))
    if let jsonURL {
      log.sessions.append(session)
      persist(log, to: jsonURL)
    }

    await announce(
      "About Face trial harness. \(trials) trial\(trials == 1 ? "" : "s"). "
        + "Config: \(configPath ?? "defaults"). Label: \(sessionLabel).", speech: speech)

    let (outcomes, fatalMessage) = await runTrialLoop(
      context: context, jsonURL: jsonURL, log: &log, session: &session)

    await chain.audio.stop()
    await source.stop()

    if let fatalMessage {
      await announce(fatalMessage, speech: speech)
      throw ExitCode.failure
    }
    await speakSessionSummary(
      outcomes: outcomes, log: log, currentLabel: sessionLabel, speech: speech)
  }

  /// The `1...trials` loop: runs each trial, persists it (flush-per-trial,
  /// per the task brief's Ctrl-C-safety requirement), and stops early —
  /// returning whatever trials completed plus a fatal-error message — if
  /// the camera feed ends unexpectedly.
  private func runTrialLoop(
    context: TrialContext, jsonURL: URL?, log: inout TrialSessionLog,
    session: inout TrialSessionLog.SessionRecord
  ) async -> (outcomes: [TrialOutcomeMetrics], fatalMessage: String?) {
    var outcomes: [TrialOutcomeMetrics] = []
    for index in 1...trials {
      guard let metrics = await runOneTrial(index: index, context: context) else {
        return (outcomes, "Camera feed ended unexpectedly mid-trial.")
      }
      outcomes.append(metrics)
      session.trials.append(TrialSessionLog.TrialRecord(index: index, metrics: metrics))
      session.aggregate = TrialSessionLog.AggregateRecord(TrialStats.aggregate(from: outcomes))
      if let jsonURL {
        log.sessions[log.sessions.count - 1] = session
        persist(log, to: jsonURL)
      }
    }
    return (outcomes, nil)
  }

  /// Pumps `engine.stream(from: source)` into `hub` for the whole session
  /// — one continuous consumer, per `TrialHub`'s own doc comment. A thrown
  /// per-frame error and a normal stream end are both "no more frames are
  /// coming" from `hub`'s point of view, so both paths converge on
  /// `markSourceEnded()`.
  private static func pumpFrames(
    engine: AnalysisEngine, source: CameraCaptureSource, hub: TrialHub
  ) async {
    do {
      for try await output in engine.stream(from: source) {
        await hub.publish(output)
      }
    } catch {
      // Falls through to markSourceEnded() below regardless.
    }
    await hub.markSourceEnded()
  }

  // MARK: - One trial

  /// Runs trial `index` end to end: the displacement-gated setup prompt,
  /// live convergence, and the spoken result. Returns `nil` only if the
  /// camera feed ended while this trial was in progress (a fatal,
  /// session-ending condition `runTrialLoop` reports and exits on) — a
  /// normal settle or timeout always returns metrics.
  func runOneTrial(index: Int, context: TrialContext) async -> TrialOutcomeMetrics? {
    guard await waitForDisplacement(index: index, context: context) else {
      return nil
    }

    await announce("Converge when the tone starts.", speech: context.speech)
    try? await Task.sleep(for: .seconds(1))

    guard let metrics = await runLiveConvergence(context: context) else {
      return nil
    }

    await speakTrialResult(metrics, speech: context.speech)
    return metrics
  }

  /// Step 1 of the protocol: "Move well out of position... press Return
  /// when set up," re-prompted (task brief) until the current smoothed
  /// error actually clears `context.displacementThreshold`. Returns
  /// `false` only if the camera feed ended while waiting.
  private func waitForDisplacement(index: Int, context: TrialContext) async -> Bool {
    await announce(
      "Trial \(index) of \(trials). Move well out of position — lean left, right, back, or "
        + "slouch. Say when: press Return.", speech: context.speech)

    while true {
      _ = await StdinInput.readLineAsync()
      if await context.hub.sourceEnded { return false }

      guard let framing = await context.hub.latest?.framing else {
        await announce(
          "No face detected — get back in view of the camera, then press Return when you're "
            + "out of position.", speech: context.speech)
        continue
      }
      let displaced = DisplacementCheck.isDisplaced(
        errorX: framing.error.x, errorY: framing.error.y, threshold: context.displacementThreshold)
      if displaced {
        return true
      }
      await announce("Not far enough out of position yet. Keep going.", speech: context.speech)
    }
  }

  /// Steps 2–4: the tone goes live, the clock starts, and this drives the
  /// real `FeedbackRouter` with every live frame until SETTLED, timeout, or
  /// the camera feed ends. Returns `nil` only for the last of those (a
  /// fatal, session-ending condition).
  private func runLiveConvergence(context: TrialContext) async -> TrialOutcomeMetrics? {
    let clock = ContinuousClock()
    let liveStart = clock.now
    var tracker = ConvergenceTracker(
      settleSeconds: settleSeconds, deadZoneX: Float(context.deadZone.horizontal),
      deadZoneY: Float(context.deadZone.vertical))
    var pauseTracker = FaceLossPauseTracker(pauseThresholdSeconds: faceLostPauseSeconds)
    var settledFired = false
    var timedOutFired = false

    let liveStream = await context.hub.beginLive()
    for await output in liveStream {
      let now = clock.now
      await context.chain.router.ingest(output, at: now)
      await announcePauseTransition(
        &pauseTracker, hasFace: output.framing != nil, now: now, context: context)
      guard !pauseTracker.isPaused else { continue }

      let elapsed = ClockMath.seconds(now - liveStart) - pauseTracker.pausedDurationSeconds
      let justSettled = ingestLiveSample(&tracker, output: output, elapsed: elapsed)
      if justSettled {
        settledFired = true
        break
      }
      if elapsed >= timeoutSeconds {
        timedOutFired = true
        break
      }
    }
    await context.hub.endLive()
    await context.chain.audio.update(nil)

    guard settledFired || timedOutFired else { return nil }
    return tracker.snapshot(timedOut: timedOutFired)
  }

  private func announcePauseTransition(
    _ pauseTracker: inout FaceLossPauseTracker, hasFace: Bool, now: ContinuousClock.Instant,
    context: TrialContext
  ) async {
    guard let event = pauseTracker.update(hasFace: hasFace, now: now) else { return }
    switch event {
    case .paused: await announce("Face lost. Trial paused.", speech: context.speech)
    case .resumed: await announce("Face reacquired. Resuming.", speech: context.speech)
    }
  }

  private func ingestLiveSample(
    _ tracker: inout ConvergenceTracker, output: EngineOutput, elapsed: Double
  ) -> Bool {
    guard let framing = output.framing else { return false }
    return tracker.ingest(
      elapsedSeconds: elapsed, errorX: framing.error.x, errorY: framing.error.y,
      inDeadZone: framing.inDeadZone)
  }

  private func speakTrialResult(_ metrics: TrialOutcomeMetrics, speech: Speech) async {
    guard !metrics.timedOut else {
      await announce("Trial timed out.", speech: speech)
      return
    }
    let seconds = metrics.tSettledSeconds ?? 0
    let overshootWord = metrics.overshootsTotal == 1 ? "overshoot" : "overshoots"
    await announce(
      "Settled in \(Self.formatSeconds(seconds)) seconds, \(metrics.overshootsTotal) "
        + "\(overshootWord).", speech: speech)
  }
}
