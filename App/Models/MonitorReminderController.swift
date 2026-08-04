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
/// ## The speech lifecycle problem (PR brief) — RESOLVED by consolidation
///
/// This controller USED TO own a separate, private `SpeechRenderer`,
/// constructed once and kept for the controller's own lifetime, because the
/// obvious alternative — `PipelineModel.speechRenderer` — used to exist only
/// between `startFeedbackChain()` and `stopFeedbackChain()`, i.e. only while
/// the pipeline was RUNNING, and this reminder only ever fires while
/// `PipelineModel.isRunning == false` (`CameraReminderStateMachine`'s
/// `isCapturing` gate) — exactly the window the old `speechRenderer` was
/// `nil`. Two independently-owned `AVSpeechSynthesizer`s speaking at once
/// would be a real bug (garbled, overlapping audio); it could not happen
/// with just these two renderers, but only because their active windows
/// were provably disjoint — an argument that does not scale to a third
/// speaker. It stopped scaling the moment hotkey confirmations (§8) needed
/// their own voice too: a global hotkey can fire at any instant, including
/// mid-utterance from either of the other two, so "disjoint time windows"
/// was no longer available as the safety argument.
///
/// The fix (this PR): `PipelineModel.speechRenderer` is now constructed
/// once in `PipelineModel.init()` and lives for the app's whole lifetime,
/// never torn down when the pipeline stops (see that property's doc
/// comment). This controller no longer owns any `SpeechRenderer` of its
/// own — `evaluate(busy:)` below speaks through `model?.speechRenderer`
/// instead, the same shared instance `FeedbackRouter` and `HotkeyCenter`
/// use. Overlap is now impossible by construction (one `AVSpeechSynthesizer`
/// always preempts its own prior utterance — see `SpeechRenderer.speak(_:)`),
/// not by an argument about which windows happen not to intersect.
///
/// ## Wiring (see `SetupWindowView`'s `monitorReminderBootstrap`)
///
/// `configure(model:)` is called once, from the Setup window's `.task` —
/// the same "first view guaranteed to exist at launch" reasoning
/// `HotkeyCenter`'s wiring doc comment already gives, since this reminder,
/// like a global hotkey, must work with no window focused. One further
/// `SetupWindowView` hook keeps it live after that: `.onChange(of:
/// model.selectedCameraID)` calls `deviceChanged()` (a new/changed camera
/// means a new CoreMediaIO device to resolve). A `SpeechConfig` change no
/// longer needs a hook here at all — now that this controller speaks
/// through the shared `model.speechRenderer` (see `evaluate(busy:)` below),
/// `PipelineModel+Audio.swift`'s `pushConfigToFeedbackChain` already
/// reaches it on every `Config` change
/// (see that method's doc comment), pipeline running or not. (Before
/// consolidation, this controller's now-removed `configChanged(old:new:)`
/// existed only to forward that same push to its OWN private renderer.)
///
/// `Config.Camera`'s debounce/delay/poll/`monitorReminderEnabled` fields
/// remain read once, at `reconfigureForCurrentDevice()` construction time,
/// and are not live-reconfigured — see that method's doc comment.
@MainActor
final class MonitorReminderController {
  private var model: PipelineModel?

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
  ///
  /// `Config.Camera`'s `busyDebounceMs`/`reminderDelayMs`/
  /// `busyPollIntervalSeconds`/`forceBusyPolling` are read HERE, once, and
  /// baked into `machine`/the CMIO provider for this controller's session —
  /// deliberately not live-reconfigured on every `Config` change (unlike
  /// `Config.speech`, which now reaches the shared `speechRenderer`
  /// unconditionally via `PipelineModel+Audio.swift`'s
  /// `pushConfigToFeedbackChain` — see the type-level doc comment's
  /// "Wiring" section). `monitorReminderEnabled` needs no such wiring at
  /// all: `evaluate(busy:)` below reads it fresh from `model` on every
  /// settle (and again at every deadline tick), so a toggle takes effect on
  /// the very next evaluation with zero plumbing. The other four fields
  /// have no debug-panel control yet (unlike `Config.audio`, which
  /// `AudioRenderer.updateConfig` does support live), so reconfiguring the
  /// CMIO listener on every unrelated keystroke elsewhere in `Config` would
  /// be churn with no observable benefit today. Revisit if a live control
  /// for those fields is ever added.
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
      // Speaks through the shared, app-lifetime `model.speechRenderer` (see
      // `PipelineModel.speechRenderer`'s doc comment) rather than a private
      // renderer of this controller's own — see the type-level doc
      // comment's "speech lifecycle problem" section for why that used to
      // be necessary and why consolidation removed the need.
      Task { await model.speechRenderer.speak(Lexicon.Reminder.cameraInUseMonitorOff) }
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
