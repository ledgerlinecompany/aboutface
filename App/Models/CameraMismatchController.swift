import AboutFaceCore

/// App-side driver for §12.3's mismatch warning: owns a
/// `CameraMismatchMonitor` (the Core polling republisher — see that type's
/// doc comment for why this signal needs a poll loop rather than a
/// listener), feeds each snapshot through `CameraMismatchClassifier.classify`
/// and `CameraMismatchStateMachine` (the pure decision logic — see those
/// types' doc comments for WHY they decide what they decide, including the
/// corrected heuristic and its accepted false positive), and publishes the
/// result as plain VoiceOver-readable text on `PipelineModel
/// .cameraMismatchWarning`. Deliberately thin (CLAUDE.md: "keep `App/`
/// thin") — every rule about WHEN to show or suppress the notice lives in
/// the Core machine; this type only wires a live multi-device CoreMediaIO
/// signal to it and turns its `Outcome` into displayable text.
///
/// ## Never spoken — visible/VoiceOver-readable only
///
/// Unlike `MonitorReminderController`, this controller never touches
/// `PipelineModel.speechRenderer`. §12.3 calls the warning "informational,"
/// not urgent, and the PR brief that built this controller was explicit:
/// About Face already gained one unprompted utterance (§12.2's reminder),
/// and adding a second automatic spoken warning is a product decision the
/// maintainer has not made. `SetupWindowView` surfaces
/// `model.cameraMismatchWarning` the same way it already surfaces
/// `monitorReminderIssue`/`hotkeyRegistrationIssue` — a plain string in its
/// own `Section`, readable by VoiceOver navigation, never announced
/// unprompted.
///
/// ## Runs regardless of `PipelineModel.isRunning` — the point of the
/// corrected heuristic
///
/// `MonitorReminderController` is only armed while About Face is idle
/// (`CameraReminderStateMachine`'s `isCapturing` gate), because §12.2's
/// signal is contaminated by About Face's own capture. `CameraMismatchClassifier`
/// sidesteps that contamination entirely by never consulting the selected
/// device's own reading (see that type's doc comment) — so this controller
/// polls continuously whenever a camera is selected, in both Setup and
/// Monitor mode, and in between. That is not an oversight; it is the reason
/// the corrected rule exists: the scenario it is FOR is About Face actively
/// monitoring camera A while the real call is on camera B, which only ever
/// happens while About Face is capturing.
///
/// ## Poll lifecycle: only while a camera is selected, only while a Setup
/// window exists
///
/// `configure(model:)` is called once from `SetupWindowView`'s `.task`,
/// same "first view guaranteed to exist at launch" reasoning
/// `monitorReminderBootstrap()` already documents. `reconfigure()` (private)
/// starts nothing at all if `model.selectedCameraID == nil` — matching
/// `MonitorReminderController.reconfigureForCurrentDevice()`'s "nothing
/// selected yet is a normal startup state" stance, and satisfying the PR
/// brief's "do not add an always-on high-frequency timer" restraint by the
/// same means that controller does: no polling happens until there is
/// something meaningful to poll for. `deviceChanged()` — wired from
/// `SetupWindowView`'s existing `.onChange(of: model.selectedCameraID)`,
/// alongside the reminder's own hook — tears down and restarts with a FRESH
/// `CameraMismatchStateMachine`, deliberately discarding any prior
/// debounce/dismiss state: a new selection is a materially different
/// comparison, not a continuation of the old one.
///
/// `Config.Camera.busyDebounceMs`/`busyPollIntervalSeconds` are read once,
/// at `reconfigure()` time, same "not live-reconfigured" posture
/// `MonitorReminderController` documents for its own analogous fields, for
/// the same reason: no debug-panel control exists yet for either, so
/// reconfiguring the poll loop on every unrelated `Config` change would be
/// churn with no observable benefit today.
/// `Config.Camera.cameraMismatchWarningEnabled` needs no such wiring —
/// `publish(classification:)` below reads it fresh from `model` on every
/// poll tick, so a toggle takes effect on the next tick with zero plumbing,
/// the same shape `monitorReminderEnabled` already uses.
@MainActor
final class CameraMismatchController {
  private var model: PipelineModel?

  private var machine: CameraMismatchStateMachine?
  private var monitor: CameraMismatchMonitor?
  private var observeTask: Task<Void, Never>?

  /// The most recent classification received from `monitor.readings` —
  /// replayed into `machine.update` by `dismiss()` so a dismissal is
  /// reflected in `model.cameraMismatchWarning` immediately, rather than
  /// waiting up to `busyPollIntervalSeconds` for the next poll tick to
  /// happen to notice the state changed.
  private var lastClassification: CameraMismatchClassification = .clear

  /// Origin for `monotonicSeconds()` — same rationale as
  /// `MonitorReminderController`'s identically-named property: caller-
  /// supplied monotonic seconds, not wall-clock time, so a clock jump can't
  /// corrupt debounce timing.
  private let clockOrigin = ContinuousClock.now

  /// Wires this controller to a running `PipelineModel`. Call once at
  /// Setup-window launch (see this type's doc comment).
  func configure(model: PipelineModel) {
    self.model = model
    reconfigure()
  }

  /// `SetupWindowView`'s `.onChange(of: model.selectedCameraID)` — see this
  /// type's doc comment for why a device change gets a fresh machine rather
  /// than continuing the old one's debounce/dismiss state.
  func deviceChanged() {
    reconfigure()
  }

  /// Suppresses the currently-showing notice for its current episode — see
  /// `CameraMismatchStateMachine`'s doc comment for exactly when it can
  /// reappear. Called from `SetupWindowView`'s dismiss button.
  func dismiss() {
    machine?.dismiss()
    publish(classification: lastClassification)
  }

  private func reconfigure() {
    guard let model else { return }
    tearDown()

    guard model.selectedCameraID != nil else {
      // Nothing selected yet: `CameraMismatchClassifier.classify` would
      // always report `.clear` for a `nil` selection anyway (see that
      // type's doc comment), so there is nothing meaningful to poll for —
      // same restraint `MonitorReminderController` applies for the same
      // starting state.
      model.cameraMismatchWarning = nil
      return
    }

    machine = CameraMismatchStateMachine(debounceMs: model.config.camera.busyDebounceMs)
    let monitor = CameraMismatchMonitor()
    self.monitor = monitor
    let intervalSeconds = model.config.camera.busyPollIntervalSeconds
    observeTask = Task { [weak self] in
      await monitor.start(intervalSeconds: intervalSeconds)
      for await readings in monitor.readings {
        if Task.isCancelled { break }
        self?.handle(readings: readings)
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

  private func handle(readings: [CMIODeviceRunningState]) {
    guard let model else { return }
    let classification = CameraMismatchClassifier.classify(
      selectedUniqueID: model.selectedCameraID, readings: readings)
    lastClassification = classification
    publish(classification: classification)
  }

  private func publish(classification: CameraMismatchClassification) {
    guard let model else { return }
    guard
      let outcome = machine?.update(
        classification: classification,
        isEnabled: model.config.camera.cameraMismatchWarningEnabled,
        now: monotonicSeconds())
    else { return }
    model.cameraMismatchWarning = Self.text(for: outcome)
  }

  /// Plain, closed-form descriptive text — NOT a `Lexicon.Phrase` (this is
  /// never spoken; see this type's doc comment), same "plain `String?`"
  /// shape `monitorReminderIssue`/`hotkeyRegistrationIssue` already use for
  /// VoiceOver-readable-but-unspoken notices. Names what is wrong in plain
  /// terms per the PR brief: that another camera appears to be in use, and
  /// that About Face may therefore be watching the wrong one.
  private static func text(for outcome: CameraMismatchStateMachine.Outcome) -> String? {
    switch outcome {
    case .noNotice:
      return nil
    case .notice(.mismatch):
      return
        "Another camera appears to be in use. About Face may be watching the wrong one — "
        + "check that your conferencing app is using the selected camera."
    case .notice(.unreliable):
      return
        "Camera status could not be read from any device. Unable to check whether another "
        + "camera is in use."
    }
  }

  private func monotonicSeconds() -> Double {
    let components = (ContinuousClock.now - clockOrigin).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
