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
    let sessionLabel =
      label ?? (configPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "defaults")
    // `nil` (and therefore no frame retention at all — see `pumpFrames`)
    // unless --snapshots was given.
    let snapshotWriter = TrialSnapshotWriter(directoryPath: snapshotsDir, label: sessionLabel)
    let pumpTask = Task<Void, Never> {
      await Self.pumpFrames(
        engine: engine, source: source, hub: hub, retainFrames: snapshotWriter != nil)
    }
    defer { pumpTask.cancel() }

    let displacementThreshold =
      Float(displacementMultiplier)
      * Float(hypot(config.deadZone.horizontal, config.deadZone.vertical))
    let context = TrialContext(
      hub: hub, chain: chain, speech: speech, displacementThreshold: displacementThreshold,
      deadZone: config.deadZone, snapshotWriter: snapshotWriter)
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
    await announceSnapshotsSummary(writer: snapshotWriter, session: session, speech: speech)
  }

  /// The task brief's "one line at session end, not per-shot chatter": a
  /// single spoken/printed summary of how many snapshot JPEGs were written,
  /// counted from the just-completed session's own trial records rather
  /// than threaded separately through the trial loop. No-op (and no line
  /// spoken) without `--snapshots`.
  private func announceSnapshotsSummary(
    writer: TrialSnapshotWriter?, session: TrialSessionLog.SessionRecord, speech: Speech
  ) async {
    guard let writer else { return }
    let count = session.trials.reduce(0) { total, trial in
      total
        + [trial.startSnapshot, trial.settledSnapshot, trial.timeoutSnapshot]
        .compactMap { $0 }.count
    }
    let word = count == 1 ? "snapshot" : "snapshots"
    await announce(
      "\(count) \(word) saved to \(writer.directory.path).", speech: speech)
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
      guard let (metrics, snapshots) = await runOneTrial(index: index, context: context) else {
        return (outcomes, "Camera feed ended unexpectedly mid-trial.")
      }
      outcomes.append(metrics)
      session.trials.append(
        TrialSessionLog.TrialRecord(
          index: index, metrics: metrics, startSnapshot: snapshots.start,
          settledSnapshot: snapshots.settled, timeoutSnapshot: snapshots.timeout))
      session.aggregate = TrialSessionLog.AggregateRecord(TrialStats.aggregate(from: outcomes))
      if let jsonURL {
        log.sessions[log.sessions.count - 1] = session
        persist(log, to: jsonURL)
      }
    }
    return (outcomes, nil)
  }

  /// Pumps frames into `hub` for the whole session — one continuous
  /// consumer, per `TrialHub`'s own doc comment. A thrown per-frame error
  /// and a normal stream end are both "no more frames are coming" from
  /// `hub`'s point of view, so both paths converge on `markSourceEnded()`.
  ///
  /// `retainFrames` selects between two equivalent-otherwise loops:
  /// without `--snapshots` this is `engine.stream(from: source)` exactly as
  /// before (zero behavioral change, zero retained frames); with it,
  /// `pumpFramesRetainingFrames` is used instead so the `CapturedFrame`
  /// behind each `EngineOutput` can be teed into `hub` alongside it.
  private static func pumpFrames(
    engine: AnalysisEngine, source: CameraCaptureSource, hub: TrialHub, retainFrames: Bool
  ) async {
    if retainFrames {
      await pumpFramesRetainingFrames(engine: engine, source: source, hub: hub)
    } else {
      do {
        for try await output in engine.stream(from: source) {
          await hub.publish(output)
        }
      } catch {
        // Falls through to markSourceEnded() below regardless.
      }
    }
    await hub.markSourceEnded()
  }

  /// `--snapshots`-only frame pump: iterates `source.frames` directly
  /// instead of `engine.stream(from:)`, which consumes and discards each
  /// `CapturedFrame` right after producing its `EngineOutput` (there is
  /// nowhere downstream of that call to recover the pixel buffer — see
  /// `AnalysisEngine.stream(from:)`). Otherwise identical to that method's
  /// own loop: same per-frame `process(_:)` call, same cancellation check,
  /// same treatment of a thrown per-frame error as "no more frames are
  /// coming" (both just return, and `pumpFrames` calls `markSourceEnded()`
  /// either way).
  private static func pumpFramesRetainingFrames(
    engine: AnalysisEngine, source: CameraCaptureSource, hub: TrialHub
  ) async {
    for await frame in source.frames {
      if Task.isCancelled { return }
      do {
        let output = try await engine.process(frame)
        await hub.publish(output, frame: frame)
      } catch {
        return
      }
    }
  }

  // MARK: - One trial

  /// Runs trial `index` end to end: the displacement-gated setup prompt,
  /// live convergence, and the spoken result. Returns `nil` only if the
  /// camera feed ended while this trial was in progress (a fatal,
  /// session-ending condition `runTrialLoop` reports and exits on) — a
  /// normal settle or timeout always returns metrics alongside whichever
  /// snapshot filenames were written (`TrialSnapshotPaths.none` without
  /// `--snapshots`).
  func runOneTrial(
    index: Int, context: TrialContext
  ) async -> (metrics: TrialOutcomeMetrics, snapshots: TrialSnapshotPaths)? {
    guard
      case .displaced(let startSnapshot) = await waitForDisplacement(index: index, context: context)
    else {
      return nil
    }

    await announce("Converge when the tone starts.", speech: context.speech)
    try? await Task.sleep(for: .seconds(1))

    guard
      let (metrics, convergenceSnapshot) = await runLiveConvergence(index: index, context: context)
    else {
      return nil
    }

    await speakTrialResult(metrics, speech: context.speech)
    var snapshots = TrialSnapshotPaths(start: startSnapshot)
    if metrics.timedOut {
      snapshots.timeout = convergenceSnapshot
    } else {
      snapshots.settled = convergenceSnapshot
    }
    return (metrics, snapshots)
  }

  /// `waitForDisplacement`'s outcome: either the camera feed ended while
  /// waiting (fatal — `runOneTrial` propagates `nil`), or the subject is
  /// confirmed displaced, carrying the go-signal snapshot's filename (`nil`
  /// without `--snapshots`, or if the write failed).
  private enum DisplacementOutcome {
    case sourceEnded
    case displaced(startSnapshot: String?)
  }

  /// Step 1 of the protocol: "Move well out of position... press Return
  /// when set up," re-prompted (task brief) until the current smoothed
  /// error actually clears `context.displacementThreshold`. That instant —
  /// the displaced starting pose the trial is about to correct from — is
  /// also the go-signal snapshot moment (task brief: "<label>-trial<N>-
  /// start.jpg").
  private func waitForDisplacement(
    index: Int, context: TrialContext
  ) async -> DisplacementOutcome {
    await announce(
      "Trial \(index) of \(trials). Move well out of position — lean left, right, back, or "
        + "slouch. Say when: press Return.", speech: context.speech)

    while true {
      _ = await StdinInput.readLineAsync()
      if await context.hub.sourceEnded { return .sourceEnded }

      guard let framing = await context.hub.latest?.framing else {
        await announce(
          "No face detected — get back in view of the camera, then press Return when you're "
            + "out of position.", speech: context.speech)
        continue
      }
      let displaced = DisplacementCheck.isDisplaced(
        errorX: framing.error.x, errorY: framing.error.y, threshold: context.displacementThreshold)
      if displaced {
        let frame = await context.hub.latestFrame
        let snapshot = context.snapshotWriter?.write(frame, trial: index, moment: .start)
        return .displaced(startSnapshot: snapshot)
      }
      await announce("Not far enough out of position yet. Keep going.", speech: context.speech)
    }
  }

  /// Steps 2–4: the tone goes live, the clock starts, and this drives the
  /// real `FeedbackRouter` with every live frame until SETTLED, timeout, or
  /// the camera feed ends. Returns `nil` only for the last of those (a
  /// fatal, session-ending condition). The frame paired with whichever
  /// `EngineOutput` sample actually triggers SETTLED or the timeout is the
  /// one snapshotted — "the frame at the moment settle fires" per the task
  /// brief, not a separately-queried "latest" that could differ by a frame
  /// or two.
  private func runLiveConvergence(
    index: Int, context: TrialContext
  ) async -> (metrics: TrialOutcomeMetrics, snapshot: String?)? {
    let clock = ContinuousClock()
    let liveStart = clock.now
    var tracker = ConvergenceTracker(
      settleSeconds: settleSeconds, deadZoneX: Float(context.deadZone.horizontal),
      deadZoneY: Float(context.deadZone.vertical))
    var pauseTracker = FaceLossPauseTracker(pauseThresholdSeconds: faceLostPauseSeconds)
    var settledFired = false
    var timedOutFired = false
    var triggerFrame: CapturedFrame?

    let liveStream = await context.hub.beginLive()
    for await sample in liveStream {
      let output = sample.output
      let now = clock.now
      await context.chain.router.ingest(output, at: now)
      await announcePauseTransition(
        &pauseTracker, hasFace: output.framing != nil, now: now, context: context)
      guard !pauseTracker.isPaused else { continue }

      let elapsed = ClockMath.seconds(now - liveStart) - pauseTracker.pausedDurationSeconds
      let justSettled = ingestLiveSample(&tracker, output: output, elapsed: elapsed)
      if justSettled {
        settledFired = true
        triggerFrame = sample.frame
        break
      }
      if elapsed >= timeoutSeconds {
        timedOutFired = true
        triggerFrame = sample.frame
        break
      }
    }
    await context.hub.endLive()
    await context.chain.audio.update(nil)

    guard settledFired || timedOutFired else { return nil }
    let moment: TrialSnapshotMoment = settledFired ? .settled : .timeout
    let snapshot = context.snapshotWriter?.write(triggerFrame, trial: index, moment: moment)
    return (tracker.snapshot(timedOut: timedOutFired), snapshot)
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
