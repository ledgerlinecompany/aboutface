import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli trial` — a repeated-measures convergence experiment: live
/// camera + the real audio feedback chain (§13 Phase 3's
/// `AudioRenderer`/`SpeechRenderer`/`FeedbackRouter(mode: .setup)`, same as
/// `replay --audio`/`audition`), measuring how quickly and how consistently
/// the maintainer reaches the ideal viewing position from a deliberately
/// bad starting position.
///
/// This is the maintainer's own proposed audition mechanism: "the correct
/// auditions might be live camera feedback plus a measure of how quickly
/// and consistently I can get to the ideal viewing position." `--config`
/// is THE comparison mechanism — run one `trial` session per tuning
/// profile (same `--json` log, different `--label`) and let the aggregate
/// numbers (and the session-to-session spoken comparison) say which is
/// better, instead of trying to A/B by memory across two separate live
/// takes.
///
/// Speech-first throughout, per the task brief: every instruction and
/// every result is both printed and spoken via `Speech`
/// (`CorpusSpeech.swift`, the same TTS wrapper `record-corpus --speak`
/// uses — full descriptive sentences, not `Lexicon.swift`'s closed
/// shipping-app vocabulary), and every announcement is state-change-based
/// (nothing repeats on a timer) with function-before-key phrasing, per the
/// `fix/recorder-vo-session` conventions ("Skip this clip: press S", never
/// "s: skip this clip").
///
/// See `TrialProtocol.swift` for the per-trial protocol implementation,
/// `TrialRuntime.swift` for the camera/frame-distribution plumbing,
/// `TrialSessionLog.swift` for the `--json` schema, `TrialMetrics.swift`
/// for the pure convergence/aggregate math, and `TrialSelfTest.swift` for
/// `--self-test-metrics`'s hand-computed verification battery.
struct Trial: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "trial",
    abstract:
      "Repeated-measures convergence trial: live camera + full audio feedback, measuring time "
      + "and consistency getting from a bad starting position to the ideal viewing position.",
    discussion: """
      Protocol per trial: "Move well out of position" (won't proceed until smoothed |error| \
      clears --displacement-multiplier times the dead zone's diagonal, so a trial always starts \
      from a genuine correction, not a trivial one) -- press Return -- "Converge when the tone \
      starts" -- a 1s pause -- then the real feedback chain goes live and the clock starts. \
      SETTLED fires the first instant the error has stayed continuously inside the dead zone for \
      --settle-seconds (default 2s); a trial that never settles within --timeout-seconds \
      (default 45s) is recorded as timed out and the harness moves on. If the face is lost for \
      more than --face-lost-pause-seconds (default 5s), the trial's clock pauses (with a spoken \
      notice) until the face returns, so a coincidental look-away never counts against the \
      measurement.

      Metrics per trial: time to first dead-zone entry, time to SETTLED, per-axis and total \
      overshoot count (sign reversals of error.x/error.y while genuinely outside the dead zone), \
      path integral of |error| over time (path efficiency), and mean |error| during the settle \
      window (steadiness). Across trials: median/mean/stddev of settled trials' times (the \
      consistency measure), total overshoots, and how many timed out.

      --config <path> (a ConfigStore-exported tuning profile) is the A/B mechanism: run one \
      `trial` session per profile, pointing --json at the same log file with a different \
      --label each time, and successive sessions accumulate into one comparable file. If the \
      log already holds a prior session under a different label, the end-of-session summary \
      also speaks a brief comparison against it (median settle time and total overshoots only).

      --self-test-metrics runs a battery of hand-computed scripted-sequence checks against the \
      pure convergence/aggregate math -- no camera or audio needed -- and exits; with --json, \
      it also appends one synthetic demonstration session so the on-disk schema can be inspected \
      without a live run.
      """
  )

  @Option(help: "Number of trials to run this session.")
  var trials = 5

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile (Debug panel Export…) to run this "
        + "session against, instead of Config.defaults. THIS is the A/B mechanism -- run one "
        + "session per profile against the same --json log."))
  var configPath: String?

  @Option(
    help: ArgumentHelp(
      "Free-text label stored with this session's results in --json, and spoken in the "
        + "end-of-session comparison. Defaults to the --config filename, or \"defaults\"."))
  var label: String?

  @Option(
    name: .customLong("settle-seconds"),
    help: "Seconds of continuous dead-zone dwell required to declare a trial SETTLED.")
  var settleSeconds: Double = 2.0

  @Option(
    name: .customLong("timeout-seconds"),
    help: ArgumentHelp(
      "Give up on a trial (recorded as timed out) after this many seconds of live convergence "
        + "time. Time spent paused for a lost face does not count against this."))
  var timeoutSeconds: Double = 45.0

  @Option(
    name: .customLong("displacement-multiplier"),
    help: ArgumentHelp(
      "A trial cannot start until smoothed |error| exceeds this multiple of the dead zone's "
        + "diagonal magnitude (hypot(deadZone.horizontal, deadZone.vertical)) -- i.e. the "
        + "subject must be genuinely displaced, not already near target."))
  var displacementMultiplier: Double = 2.5

  @Option(
    name: .customLong("face-lost-pause-seconds"),
    help: "Pause a trial's clock and speak a notice once the face has been undetected this long.")
  var faceLostPauseSeconds: Double = 5.0

  @Option(
    name: .customLong("json"),
    help: ArgumentHelp(
      "Path to an append-mode JSON session log. Successive `trial` sessions (e.g. one per "
        + "tuning profile) accumulate into this one file so they stay comparable."))
  var jsonPath: String?

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

  @Flag(
    name: .customLong("self-test-metrics"),
    help: ArgumentHelp(
      "Run a battery of hand-computed scripted-sequence checks against the pure "
        + "convergence/aggregate metric functions (no camera or audio needed), print PASS/FAIL, "
        + "and exit. With --json, also appends one synthetic demonstration session."))
  var selfTestMetrics = false

  func run() async throws {
    if selfTestMetrics {
      try runSelfTest()
      return
    }
    guard trials >= 1 else {
      print("--trials must be at least 1.")
      throw ExitCode.failure
    }

    let speech = Speech()

    let config: Config
    do {
      config = try AudioCLISupport.loadConfig(configPath: configPath)
    } catch {
      await announce("Could not load --config: \(error).", speech: speech)
      throw ExitCode.failure
    }

    guard
      let source = TrialCameraSource.make(device: device, width: width, height: height, fps: fps)
    else {
      await announce(
        "No camera available: no default video device was found (e.g. headless CI/no hardware).",
        speech: speech)
      throw ExitCode.failure
    }

    do {
      try await source.start()
    } catch {
      await announce(
        "Could not start capture: \(error). If this is a permission problem, grant camera "
          + "access in System Settings, Privacy and Security, Camera, and try again.",
        speech: speech)
      throw ExitCode.failure
    }

    let chain: AudioCLISupport.FeedbackChain
    do {
      chain = try await AudioCLISupport.makeFeedbackChain(config: config)
    } catch {
      await source.stop()
      await announce("\(error)", speech: speech)
      throw ExitCode.failure
    }

    try await runSession(config: config, source: source, chain: chain, speech: speech)
  }

  /// Runs `TrialSelfTest`'s battery, prints PASS/FAIL per check, and (with
  /// `--json`) appends the synthetic demonstration session. Exits non-zero
  /// if any check failed, so this is meaningful in an automated context
  /// too (e.g. a maintainer script that runs it before a real session).
  private func runSelfTest() throws {
    let failures = TrialSelfTest.run()
    if failures.isEmpty {
      print("trial --self-test-metrics: all checks passed.")
    } else {
      print("trial --self-test-metrics: \(failures.count) check(s) FAILED:")
      for failure in failures {
        print("  \(failure.name): \(failure.detail)")
      }
    }

    if let jsonPath {
      let url = URL(fileURLWithPath: jsonPath)
      var log = TrialSessionStore.load(from: url)
      log.sessions.append(TrialSelfTest.syntheticSession())
      do {
        try TrialSessionStore.write(log, to: url)
        print(
          "Wrote a synthetic demonstration session to \(jsonPath) (label \"self-test-synthetic\").")
      } catch {
        print("Warning: could not write synthetic session to \(jsonPath): \(error)")
      }
    }

    guard failures.isEmpty else { throw ExitCode.failure }
  }
}
