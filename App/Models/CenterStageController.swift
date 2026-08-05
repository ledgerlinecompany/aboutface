import AboutFaceCore

/// App-side driver for §12.5's Center Stage awareness: owns a
/// `CenterStageMonitor` (the Core polling republisher for the currently
/// selected device — see that type's doc comment for why this signal needs
/// a poll loop rather than a listener), feeds each reading through
/// `CenterStageClassifier.classify` and `CenterStageStateMachine` (the pure
/// decision logic — see those types' doc comments for WHY they decide what
/// they decide, including the `.unknown`/not-active distinction), and both
/// (a) publishes a VoiceOver-readable status string on
/// `PipelineModel.centerStageNotice`, and (b) drives
/// `FeedbackRouter.setCenterStageActive(_:at:)` with the resulting boolean.
/// Deliberately thin (CLAUDE.md: "keep `App/` thin") — every rule about WHEN
/// Center Stage is considered active lives in the Core machine; this type
/// only wires a live per-device AVFoundation signal to it.
///
/// ## Runs regardless of `PipelineModel.isRunning`
///
/// Same posture as `CameraMismatchController`: `CenterStageReading
/// .automaticFramingInEffect` is observable device-wide without this app
/// holding the camera (§12.5's "the blind spot is narrower than first
/// documented" finding), so there is no reason to wait for capture to start.
/// Polling continuously — in Setup, in Monitor, and in between — means the
/// Setup window's notice is already current the moment the user opens it,
/// and `FeedbackRouter.setCenterStageActive` is a no-op until a
/// `FeedbackRouter` actually exists (`model.feedbackRouter == nil` while
/// idle — see `handle(reading:)` below).
///
/// ## Poll lifecycle: only while a camera is selected, only while a Setup
/// window exists
///
/// `configure(model:)` is called once from `SetupWindowView`'s `.task`, same
/// "first view guaranteed to exist at launch" reasoning
/// `CameraMismatchController`/`monitorReminderBootstrap()` already document.
/// `deviceChanged()` — wired from `SetupWindowView`'s existing
/// `.onChange(of: model.selectedCameraID)`, alongside the other two
/// controllers' own hooks — tears down and restarts with a FRESH
/// `CenterStageStateMachine`, discarding any prior debounce state: a new
/// selection is a materially different device, not a continuation of the
/// old one's reading. `reconfigure()` starts nothing at all if
/// `model.selectedCameraID == nil`, satisfying the "no always-on
/// high-frequency timer" restraint the same way `CameraMismatchController`
/// does.
///
/// `Config.Camera.centerStageDebounceMs`/`centerStagePollIntervalSeconds` are
/// read once, at `reconfigure()` time, same "not live-reconfigured" posture
/// the other two controllers document for their own analogous fields. These
/// are §12.5's OWN knobs, not the `busy*` pair the first wiring reused — see
/// `centerStagePollIntervalSeconds`'s doc comment for the field finding that
/// forced the split (at 1 Hz + 2000 ms, the arrival chime beat the Center
/// Stage signal, celebrating a correction the OS had just made for the user).
/// `Config.Camera.centerStageAwarenessEnabled` needs no such wiring — this
/// controller reads it fresh from `model` on every poll tick via
/// `CenterStageStateMachine.update(signal:isEnabled:now:)`.
///
/// ## The debug-panel override wins, and never corrupts the honest notice
///
/// `PipelineModel.centerStageDebugOverride` (`nil`/`true`/`false`) lets the
/// maintainer force the router's boolean from `DebugPanelView` regardless of
/// what the poller reports — see that property's doc comment for why a
/// tri-state, not a plain `Bool`. `handle(reading:)` below always resolves
/// the value it sends to the router as `model.centerStageDebugOverride ??
/// machine.routerActive`, read fresh on every tick, so a poll landing while
/// an override is engaged can never silently revert it. Crucially, the
/// override never touches `model.centerStageNotice`: that string is built
/// from the machine's `Outcome` alone, so the Setup window keeps reporting
/// what the hardware actually says even while the router is being forced —
/// a forced value can only ever show up as a behavior (feedback suppressed
/// or not), never as a fabricated "reading."
@MainActor
final class CenterStageController {
  private var model: PipelineModel?

  private var machine: CenterStageStateMachine?
  private var monitor: CenterStageMonitor?
  private var observeTask: Task<Void, Never>?

  /// Origin for `monotonicSeconds()` below — caller-supplied monotonic
  /// seconds, not wall-clock time, so a clock jump can't corrupt debounce
  /// timing (same rationale every other controller in this file's family
  /// documents).
  private let clockOrigin = ContinuousClock.now

  /// Wires this controller to a running `PipelineModel`. Call once at
  /// Setup-window launch (see this type's doc comment).
  func configure(model: PipelineModel) {
    self.model = model
    reconfigure()
  }

  /// `SetupWindowView`'s `.onChange(of: model.selectedCameraID)` — see this
  /// type's doc comment for why a device change gets a fresh machine rather
  /// than continuing the old one's debounce state.
  func deviceChanged() {
    reconfigure()
  }

  /// Called immediately when `DebugPanelView`'s tri-state override changes,
  /// so a forced value takes effect right away rather than waiting up to
  /// `centerStagePollIntervalSeconds` for the next poll tick to notice —
  /// see this type's doc comment ("The debug-panel override wins"). Uses the
  /// machine's already-settled `routerActive` rather than re-reading
  /// hardware: the override changed, not the underlying signal, so there is
  /// nothing new to classify.
  func overrideChanged() {
    Task { await pushToRouter() }
  }

  private func reconfigure() {
    guard let model else { return }
    tearDown()

    guard let deviceID = model.selectedCameraID else {
      // Nothing selected yet is a normal startup state, not a failure — same
      // restraint `CameraMismatchController`/`MonitorReminderController`
      // apply for the same starting state.
      model.centerStageNotice = nil
      return
    }

    machine = CenterStageStateMachine(debounceMs: model.config.camera.centerStageDebounceMs)
    let monitor = CenterStageMonitor()
    self.monitor = monitor
    let intervalSeconds = model.config.camera.centerStagePollIntervalSeconds
    observeTask = Task { [weak self] in
      await monitor.start(uniqueID: deviceID, intervalSeconds: intervalSeconds)
      for await reading in monitor.readings {
        if Task.isCancelled { break }
        await self?.handle(reading: reading)
      }
    }
  }

  private func tearDown() {
    observeTask?.cancel()
    observeTask = nil
    if let monitor {
      Task { await monitor.stop() }
    }
    monitor = nil
    machine = nil
  }

  private func handle(reading: CenterStageDeviceReading) async {
    guard let model else { return }
    let signal = CenterStageClassifier.classify(reading)
    guard
      let outcome = machine?.update(
        signal: signal, isEnabled: model.config.camera.centerStageAwarenessEnabled,
        now: monotonicSeconds())
    else { return }
    model.centerStageNotice = Self.text(for: outcome)
    await pushToRouter()
  }

  /// The one call site that actually calls
  /// `FeedbackRouter.setCenterStageActive(_:at:)` — shared by `handle(reading:)`
  /// (a fresh poll tick) and `overrideChanged()` (an immediate override
  /// flip), so both paths resolve the override exactly the same way. A
  /// no-op if the pipeline isn't running (`model.feedbackRouter == nil`);
  /// the router starts with `centerStageActive == false` and the very next
  /// tick after `startFeedbackChain()` pushes the current truth.
  private func pushToRouter() async {
    guard let model else { return }
    let effectiveActive = model.centerStageDebugOverride ?? (machine?.routerActive ?? false)
    await model.feedbackRouter?.setCenterStageActive(effectiveActive, at: .now)
  }

  /// Plain, closed-form descriptive text — NOT a `Lexicon.Phrase` (this is
  /// never spoken here; the spoken half is
  /// `FeedbackRouter.setCenterStageActive`'s own rising/falling-edge
  /// notice). Same "plain `String?`" shape `cameraMismatchWarning`/
  /// `virtualCameraWarning` already use.
  private static func text(for outcome: CenterStageStateMachine.Outcome) -> String? {
    switch outcome {
    case .disabled:
      return nil
    case .active:
      // Longer than the spoken phrase on purpose. This is the read-at-leisure
      // surface, so it carries the tradeoff §12.5 measured (2026-08-05):
      // Center Stage loses the face roughly ten times as often as ordinary
      // movement does, because Vision cannot track through the crop being
      // re-aimed. The maintainer decided this belongs here rather than in the
      // spoken notice — learned once, in a place it can be re-read, instead
      // of lengthening an utterance heard on every toggle.
      return "Center Stage is on. Framing is automatic. Face tracking is less reliable while "
        + "Center Stage re-aims the camera, so brief face-lost alerts are suppressed."
    case .notActive:
      return "Center Stage is off. Manual framing required."
    case .unknown:
      return "Center Stage status could not be determined for the selected camera."
    }
  }

  private func monotonicSeconds() -> Double {
    let components = (ContinuousClock.now - clockOrigin).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
