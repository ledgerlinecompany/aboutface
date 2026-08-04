import AboutFaceCore

/// App-side driver for §12.2/§16.4's rising-edge camera-in-use reminder:
/// observes `CMIOCameraBusyProvider`, feeds `CameraReminderStateMachine`
/// (the pure decision logic — see that type's doc comment in
/// `AboutFaceCore` for WHY it decides what it decides), and speaks the
/// result. Deliberately thin (CLAUDE.md: "keep `App/` thin") — every rule
/// about WHEN to fire lives in the Core machine; this type only wires a
/// live CoreMediaIO signal to it and turns `.speakNow` into a spoken
/// utterance.
///
/// ## Ticking a pending fire (§12.2 field-finding delay)
///
/// `CameraReminderStateMachine.update` can now return `.pending(deadline:)`
/// instead of resolving immediately — the maintainer's field finding added
/// `Config.Camera.reminderDelayMs` between a settled rising edge and
/// speech, and the machine re-validates its gates fresh at that deadline
/// rather than trusting the edge-time read (see the Core type's doc
/// comment for why). The CoreMediaIO listener this controller observes
/// only fires `onChange`, so if the busy signal is not what changes during
/// the delay (the common case — the call just keeps running), nothing
/// would ever call `update` again at the deadline unless this controller
/// arranges it. `evaluate(busy:)` does that: on `.pending(deadline:)` it
/// schedules exactly one `pendingFireTask`, slept for the remaining time
/// to `deadline`, that calls `evaluate(busy:)` again — which itself either
/// reschedules (still pending, e.g. re-armed after a fall+rise), resolves
/// to speech, or drops silently. `pendingFireTask` exists only between an
/// arm and its resolution, per CLAUDE.md's ban on an always-on poller: no
/// timer runs while nothing is pending, and at most one is ever scheduled
/// at a time (a fresh `.pending` outcome cancels and replaces it, never
/// stacks another one alongside it).
///
/// ## The speech lifecycle problem (PR brief)
///
/// `PipelineModel.speechRenderer` exists only between `startFeedbackChain()`
/// and `stopFeedbackChain()` — i.e. only while the pipeline is RUNNING. This
/// reminder is only ever allowed to fire while `PipelineModel.isRunning ==
/// false` (`CameraReminderStateMachine`'s `isCapturing` gate), which is
/// exactly the window `PipelineModel.speechRenderer` is `nil`. So this
/// controller owns a SEPARATE `SpeechRenderer`, constructed once and kept
/// for the controller's own lifetime — which is the app's lifetime, same
/// pattern as `HotkeyCenter` (`AboutFaceApp`'s single `@State`).
///
/// Two independently-owned `AVSpeechSynthesizer`s speaking at once would be
/// a real bug (garbled, overlapping audio) — but it cannot happen here, and
/// not by luck: `reminderSpeech.speak(_:)` is only ever called from
/// `evaluate(busy:)` below when `CameraReminderStateMachine.update` returns
/// `.speakNow`, which per that type's own contract only happens when
/// `isCapturing == false` — checked fresh at that exact instant, whether
/// this is the original edge-settle call or a later deadline tick (§12.2
/// field-finding delay; see "Ticking a pending fire" above). `isCapturing`
/// is read from `PipelineModel.isRunning` at that exact instant (see
/// `evaluate(busy:)`), and `PipelineModel.isRunning == false` is precisely
/// the condition under which `PipelineModel.speechRenderer` is `nil` and
/// has nothing queued. The two renderers' active windows are disjoint BY
/// CONSTRUCTION — the same gate that decides whether to speak at all also
/// guarantees the pipeline's own renderer is silent when it does — not by
/// a lock or a shared mutable flag either renderer could race on.
///
/// ## Wiring (see `SetupWindowView`'s `monitorReminderBootstrap`)
///
/// `configure(model:)` is called once, from the Setup window's `.task` —
/// the same "first view guaranteed to exist at launch" reasoning
/// `HotkeyCenter`'s wiring doc comment already gives, since this reminder,
/// like a global hotkey, must work with no window focused. Two further
/// `SetupWindowView` hooks keep it live after that: `.onChange(of:
/// model.selectedCameraID)` calls `deviceChanged()` (a new/changed camera
/// means a new CoreMediaIO device to resolve), and `.onChange(of:
/// model.config)` calls `configChanged(old:new:)` (currently only acts on
/// `old.speech != new.speech` — see that method's doc comment for why
/// `Config.Camera`'s debounce/delay/poll fields are read once rather than
/// live-reconfigured).
@MainActor
final class MonitorReminderController {
  private var model: PipelineModel?
  private let reminderSpeech = SpeechRenderer()

  private var machine: CameraReminderStateMachine?
  private var busyMonitor: CameraInUseMonitor?
  private var observeTask: Task<Void, Never>?
  private var settleTask: Task<Void, Never>?

  /// Ticks a `.pending(deadline:)` outcome forward to its resolution — see
  /// this type's doc comment ("Ticking a pending fire"). Distinct from
  /// `settleTask`: that one advances the BUSY-SIGNAL debounce; this one
  /// advances the SPEECH delay that starts only after that debounce has
  /// already settled on a rising edge. Both can be in flight briefly at
  /// once (a fresh busy change arriving while an older fire is still
  /// pending), and each is canceled/replaced independently.
  private var pendingFireTask: Task<Void, Never>?

  /// Origin for `monotonicSeconds()` below — `CameraReminderStateMachine`
  /// wants caller-supplied monotonic seconds (same contract
  /// `CameraGatingStateMachine` documents), not wall-clock time, so a clock
  /// jump (NTP adjustment, sleep/wake) can't corrupt debounce timing.
  private let clockOrigin = ContinuousClock.now

  /// Wires this controller to a running `PipelineModel` and resolves the
  /// current `selectedCameraID`. Call once at Setup-window launch (see this
  /// type's doc comment).
  func configure(model: PipelineModel) {
    self.model = model
    reconfigureForCurrentDevice()
  }

  /// `SetupWindowView`'s `.onChange(of: model.selectedCameraID)` — a new
  /// camera means a new `AVCaptureDevice.uniqueID` to resolve to a
  /// `CMIOObjectID`, so the old observation is torn down and a fresh
  /// `CMIOCameraBusyProvider` constructed for it.
  func deviceChanged() {
    reconfigureForCurrentDevice()
  }

  /// `SetupWindowView`'s `.onChange(of: model.config)`. Only
  /// `old.speech != new.speech` does anything here — §6.3's "changing any
  /// slider visibly changes engine behavior" applied to `reminderSpeech`
  /// specifically, since `PipelineModel+Audio.swift`'s
  /// `pushConfigToFeedbackChain` only reaches the PIPELINE's speech
  /// renderer, never this controller's own.
  ///
  /// `Config.Camera`'s debounce/delay/poll/`monitorReminderEnabled` fields
  /// are deliberately NOT reconfigured here. `monitorReminderEnabled` needs
  /// no wiring at all — `evaluate(busy:)` below reads it fresh from `model`
  /// on every settle (and again at every deadline tick), so a toggle takes
  /// effect on the very next evaluation with zero plumbing.
  /// `busyDebounceMs`/`reminderDelayMs`/`busyPollIntervalSeconds`/
  /// `forceBusyPolling` ARE baked into `machine`/the CMIO provider at
  /// construction time and stay there for this controller's session; no
  /// debug-panel control exists yet to edit them live (unlike
  /// `Config.audio`, which `AudioRenderer.updateConfig` does support live —
  /// see `PipelineModel+Audio.swift`'s doc comment), so reconfiguring the
  /// CMIO listener on every unrelated keystroke elsewhere in `Config`
  /// would be churn with no observable benefit today. Revisit if a live
  /// control for those fields is ever added.
  func configChanged(old: Config, new: Config) {
    guard old.speech != new.speech else { return }
    Task { await reminderSpeech.updateConfig(new.speech) }
  }

  // MARK: - Device (re)resolution

  /// Tears down any live observation and, if a camera is selected, attempts
  /// to resolve it to a CoreMediaIO device and start watching it.
  ///
  /// ## `CMIOCameraBusyProvider.init` throwing
  ///
  /// Per this PR's brief: an unresolvable device must not silently arm
  /// nothing and say nothing — that is exactly the failure shape §12.2's
  /// own finding warns about (`isInUseByAnotherApplication` "also worked,
  /// also returned a plausible `false`... not caught by anything in the
  /// code admitting uncertainty"). So a thrown
  /// `CMIOCameraBusyProviderError.deviceNotFound` is written to
  /// `PipelineModel.monitorReminderIssue`, a visible, VoiceOver-readable
  /// property `SetupWindowView` surfaces alongside `captureErrorMessage` —
  /// never just a silently-absent reminder.
  private func reconfigureForCurrentDevice() {
    guard let model else { return }
    tearDownObservation()

    guard let deviceID = model.selectedCameraID else {
      // Nothing selected yet is a normal startup state, not a failure —
      // distinct from "selected but unresolvable" below.
      model.monitorReminderIssue = nil
      return
    }

    do {
      let provider = try CMIOCameraBusyProvider(
        deviceUniqueID: deviceID,
        pollIntervalSeconds: model.config.camera.busyPollIntervalSeconds,
        forcePolling: model.config.camera.forceBusyPolling
      )
      model.monitorReminderIssue = nil
      machine = CameraReminderStateMachine(
        debounceMs: model.config.camera.busyDebounceMs,
        delayMs: model.config.camera.reminderDelayMs
      )
      startObserving(CameraInUseMonitor(provider: provider))
    } catch {
      machine = nil
      model.monitorReminderIssue =
        "Camera-in-use reminder unavailable for the selected camera (\(error))."
    }
  }

  private func startObserving(_ monitor: CameraInUseMonitor) {
    busyMonitor = monitor
    observeTask = Task { [weak self] in
      await monitor.start()
      for await busy in monitor.busyStates {
        if Task.isCancelled { break }
        await self?.handleBusyChange(busy)
      }
    }
  }

  private func tearDownObservation() {
    observeTask?.cancel()
    observeTask = nil
    settleTask?.cancel()
    settleTask = nil
    pendingFireTask?.cancel()
    pendingFireTask = nil
    if let busyMonitor {
      Task { await busyMonitor.stop() }
    }
    busyMonitor = nil
  }

  // MARK: - Debounced edge evaluation

  /// `CameraReminderStateMachine.update` needs a re-invocation at
  /// `pendingSince + debounceSeconds` to actually SETTLE a transition —
  /// `CMIOCameraBusyProvider`'s `onChange` only fires again when the raw
  /// value itself changes, not on a timer, so nothing would ever call
  /// `update` a second time for a value that changes once and then holds.
  /// This is exactly a classic debounce: cancel any previously-scheduled
  /// settle, evaluate immediately with the new raw value (covers the case
  /// where the debounce window has already elapsed, e.g. after being
  /// coalesced by rapid flapping), and schedule ONE more evaluation
  /// `debounceMs` out in case nothing else changes before then.
  private func handleBusyChange(_ busy: Bool) async {
    settleTask?.cancel()
    evaluate(busy: busy)

    guard let debounceMs = model?.config.camera.busyDebounceMs else { return }
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(debounceMs))
      guard !Task.isCancelled else { return }
      self?.evaluate(busy: busy)
    }
  }

  /// The one call site that reads `isCapturing`/`isSilenced`/`isEnabled` —
  /// deliberately fresh from `model` on every call rather than cached,
  /// since `CameraReminderStateMachine` consults them at TWO separate
  /// instants (edge-settle, and again at the delay's deadline — see that
  /// type's doc comment) and both reads must be live, not a value carried
  /// over from an earlier call.
  private func evaluate(busy: Bool) {
    guard let model else { return }
    guard
      let outcome = machine?.update(
        busy: busy,
        isCapturing: model.isRunning,
        isSilenced: model.isSilenced,
        isEnabled: model.config.camera.monitorReminderEnabled,
        now: monotonicSeconds()
      )
    else { return }

    switch outcome {
    case .nothing:
      pendingFireTask?.cancel()
      pendingFireTask = nil
    case .pending(let deadline):
      schedulePendingFireTick(deadline: deadline, busy: busy)
    case .speakNow:
      pendingFireTask?.cancel()
      pendingFireTask = nil
      Task { await reminderSpeech.speak(Lexicon.Reminder.cameraInUseMonitorOff) }
    }
  }

  /// Schedules the ONE re-invocation `.pending(deadline:)` needs — see this
  /// type's doc comment ("Ticking a pending fire"). Cancels any
  /// already-scheduled tick first: a fresh `.pending` outcome always
  /// supersedes an older one (same deadline reconfirmed, or a new deadline
  /// from a fresh rising edge after a fall+rise), never stacks a second
  /// timer alongside it. `busy` is the value that produced this outcome,
  /// carried forward into the tick's own `evaluate(busy:)` call since the
  /// CoreMediaIO listener may not fire again before `deadline` (only
  /// `onChange`, per this type's doc comment).
  private func schedulePendingFireTick(deadline: Double, busy: Bool) {
    pendingFireTask?.cancel()
    let remainingSeconds = max(0, deadline - monotonicSeconds())
    let remainingMs = Int((remainingSeconds * 1000).rounded(.up))
    pendingFireTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(remainingMs))
      guard !Task.isCancelled else { return }
      self?.evaluate(busy: busy)
    }
  }

  private func monotonicSeconds() -> Double {
    let components = (ContinuousClock.now - clockOrigin).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
