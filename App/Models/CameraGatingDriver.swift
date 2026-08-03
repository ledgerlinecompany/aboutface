import AboutFaceCore

/// §12.2's App-side gating driver: the thin layer that connects
/// `CameraInUseMonitor` (the `AVFoundation`-backed busy/free probe) and
/// `CameraGatingStateMachine` (the pure, already-tested decision machine —
/// both `AboutFaceCore/Capture/CameraGating.swift`) to a live
/// `PipelineModel`. Neither of those two types knows the other exists by
/// design (`CameraGating.swift`'s own doc comment); this is where they
/// meet. It owns no decision logic of its own beyond "which
/// `PipelineModel` call does each `CameraGatingEvent` mean" — everything
/// else (debounce, the configured/mode/busy rule table) already lives in
/// the tested Core machine (CLAUDE.md: "keep logic in `AboutFaceCore`, keep
/// `App/` thin").
///
/// ## Lifecycle
///
/// One instance, owned by `AboutFaceApp` as `@State` for the app's
/// lifetime (same pattern as `HotkeyCenter`) — `configure(model:)` is
/// called once, from `SetupWindowView`'s `.task` (see that view's
/// `cameraGatingBootstrap()`), and `selectedCameraDidChange(_:)` from its
/// `.onChange(of: model.selectedCameraID)`. The actual observation Task is
/// owned by THIS object, not by any SwiftUI view's `.task` — it must keep
/// running even if the Setup window is closed, since gating Monitor
/// activation during a call is exactly the scenario where no window is
/// open (§5.2: "Background, no window").
///
/// ## Why pull `isRunning`/`mode`/`isConfigured` instead of observing them
///
/// The machine needs the CURRENT `appConfigured` flag and `CameraGatingMode`
/// only at the moment a busy/free observation arrives — there is no need to
/// track their changes independently the way `selectedCameraID` (which
/// determines WHICH device to watch) has to be. Reading `model.isRunning`,
/// `model.mode`, and `model.config.isConfigured` fresh inside `handle
/// (busy:)` below is simpler than wiring a second reactive observation path
/// and is exactly as correct: `CameraGatingStateMachine.update(_:)` only
/// ever runs in response to a busy-signal observation anyway, so "the
/// values as of the most recent observation" is already the right
/// semantics — a `mode` change with no accompanying busy/free transition
/// has nothing for the machine to react to until the NEXT observation
/// arrives regardless of how it is read.
@MainActor
final class CameraGatingDriver {
  private weak var model: PipelineModel?
  private var machine: CameraGatingStateMachine?
  private var monitor: CameraInUseMonitor?
  private var observeTask: Task<Void, Never>?

  /// Fixed reference instant this driver was created at — `machine.update
  /// (now:)` wants monotonic seconds as a plain `Double` (so
  /// `CameraGatingStateMachine` itself never needs to import `Foundation`
  /// or touch a clock type — see that type's own doc comment), and
  /// `ContinuousClock.Instant` has no absolute epoch to convert from
  /// directly. Elapsed time since THIS instant, converted once per
  /// observation in `monotonicSeconds()` below, is all `update(now:)`
  /// actually needs: a value that only ever moves forward.
  private let epoch = ContinuousClock.now

  /// Wires this driver to a running `PipelineModel` and starts watching
  /// its currently-selected camera. Call once at app startup (see
  /// `SetupWindowView`'s `cameraGatingBootstrap()`); safe to call more than
  /// once (idempotent past the first call) since nothing else re-invokes
  /// it today.
  func configure(model: PipelineModel) {
    guard self.model == nil else { return }
    self.model = model
    machine = CameraGatingStateMachine(debounceMs: model.config.camera.busyDebounceMs)
    restartObserving(for: model.selectedCameraID)
  }

  /// `SetupWindowView`'s `.onChange(of: model.selectedCameraID)` — the
  /// camera picker is the only place that field changes today. Restarts
  /// observation on the newly-selected device; a `nil` selection (task
  /// brief: "If no camera is selected, there is nothing to gate") tears
  /// down observation cleanly instead of watching a default device.
  func selectedCameraDidChange(_ newDeviceID: String?) {
    restartObserving(for: newDeviceID)
  }

  private func restartObserving(for deviceID: String?) {
    let oldTask = observeTask
    let oldMonitor = monitor
    observeTask = nil
    monitor = nil

    guard let deviceID else {
      oldTask?.cancel()
      Task { await oldMonitor?.stop() }
      return
    }

    // §12.2's provider-level tunables (`AVCaptureDeviceBusyProvider`'s doc
    // comment): `busyPollIntervalSeconds` only matters on the polling
    // fallback path, `forceBusyPolling` is the escape hatch for a live
    // finding that KVO registers but never fires. Both Config-keyed (§0),
    // read fresh here rather than defaulted, so a maintainer flipping
    // `forceBusyPolling` after a live-camera finding takes effect on the
    // next camera selection/app launch without this file changing.
    let cameraConfig = model?.config.camera
    let newMonitor = CameraInUseMonitor(
      deviceUniqueID: deviceID,
      pollIntervalSeconds: cameraConfig?.busyPollIntervalSeconds ?? 1.0,
      forcePolling: cameraConfig?.forceBusyPolling ?? false
    )
    monitor = newMonitor
    observeTask = Task { [weak self] in
      // Cancel and fully stop the PREVIOUS observation before starting the
      // new one — `stop()` (not just `cancel()`) is what makes the old
      // monitor's `busyStates` stream finish, which is what actually lets
      // its `for await` loop (potentially still suspended below, in a
      // different Task instance) return rather than leak. See
      // `CameraInUseMonitor.stop()`'s doc comment.
      oldTask?.cancel()
      await oldMonitor?.stop()
      await newMonitor.start()
      for await busy in newMonitor.busyStates {
        guard let self else { return }
        await self.handle(busy: busy)
      }
    }
  }

  private func handle(busy: Bool) async {
    guard let model, var machine = self.machine else { return }
    let events = machine.update(
      selectedDeviceBusy: busy,
      appConfigured: model.config.isConfigured,
      mode: Self.gatingMode(isRunning: model.isRunning, mode: model.mode),
      now: monotonicSeconds()
    )
    self.machine = machine
    for event in events {
      await apply(event, to: model)
    }
  }

  private func monotonicSeconds() -> Double {
    let elapsed = epoch.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  private static func gatingMode(isRunning: Bool, mode: FeedbackMode) -> CameraGatingMode {
    guard isRunning else { return .off }
    switch mode {
    case .setup: return .setup
    case .monitor: return .monitor
    }
  }

  /// Applies one emitted event — the App-side half of `CameraGating.swift`'s
  /// rules table. Follows it exactly (task brief: "do not improvise
  /// transitions it doesn't specify"); the three cases below are
  /// deliberately NOT collapsed into shared code, because `.activateMonitor`
  /// and `.leaveSetup` need visibly different `PipelineModel` call
  /// sequences despite both being able to leave the pipeline in Monitor
  /// mode (task brief: "do not silently turn one into the other").
  private func apply(_ event: CameraGatingEvent, to model: PipelineModel) async {
    switch event {
    case .activateMonitor:
      // Rules table: only fires when `mode == .off`, i.e. the pipeline is
      // not running at all. `setMode(_:)` while stopped just flips the
      // `mode` field (its capture-restart half no-ops on a stopped
      // pipeline), so `start()` right after opens the camera directly at
      // Monitor's 640×480@15 format — never briefly at Setup's before a
      // second restart. Same sequence `PipelineModel.toggleMonitor()`'s
      // `.startMonitor` case uses, for the same reason.
      await model.setMode(.monitor)
      await model.start()

    case .deactivateMonitor:
      // Rules table: only fires when `mode == .monitor` and the device just
      // freed — the call ended. Stops the pipeline entirely rather than
      // switching back to Setup: §5.2 exists to run quietly DURING a call,
      // and Setup's continuous, unrate-limited chatter (§5.1) is not
      // something to launch unattended the instant a call ends. This is
      // the symmetric inverse of `.activateMonitor` above — activation
      // started from a fully stopped pipeline, so deactivation returns it
      // to that same resting state. (Ambiguous in the task brief beyond
      // "leave Monitor" — this is the maintainer-facing decision called
      // out in the PR report; flag if a return to Setup was intended
      // instead.)
      await model.stop()

    case .leaveSetup:
      // Rules table: only fires when `mode == .setup`, and the EVENT
      // itself fires REGARDLESS of `appConfigured` (that row reads "—") —
      // but the table only decides WHICH event to emit; it says nothing
      // about what leaving Setup should leave the pipeline IN, and that
      // second question does have a §16.4 dimension this driver has to
      // answer on its own. Consulting `model.config.isConfigured` here,
      // even though the table doesn't gate this row on it, is NOT the
      // same mistake as silently turning `.leaveSetup` into
      // `.activateMonitor` (the thing to avoid, per the type doc comment
      // above) — it is this driver making its own §16.4-consistent choice
      // about the DESTINATION of an event the table already decided to
      // emit unconditionally.
      //
      // Configured: switch the ALREADY-RUNNING pipeline to Monitor in
      // place (no `start()` — nothing to start), matching §12.2's own
      // framing: "the app stops chirping once the call starts," not "the
      // app stops." Unconfigured: stop outright, same reasoning as
      // `.deactivateMonitor` above — landing an unconfigured, unattended
      // install in Monitor the instant a call starts is exactly what
      // §16.4 exists to prevent, and `.leaveSetup` firing unconditionally
      // does not get to override that.
      //
      // Known gap this does NOT fix (flagged in the PR report, not this
      // branch's to solve — `CameraGating.swift` is merged/tested and not
      // mine to rewrite): once this busy transition is consumed here,
      // `CameraGatingStateMachine`'s internal `debouncedBusy` is already
      // `true`. If the unconfigured branch below stops the pipeline and
      // the user configures the app (e.g. captures a target) LATER,
      // mid-call, nothing re-observes the free→busy edge that already
      // happened, so `.activateMonitor` will not retroactively fire —
      // Monitor stays off for the rest of that call. This only matters
      // for a same-call configure-after-join sequence; the ordinary
      // "frame yourself in Setup, then join a call" path this fix
      // restores does not hit it.
      if model.config.isConfigured {
        await model.setMode(.monitor)
      } else {
        await model.stop()
      }
    }
  }

  deinit {
    MainActor.assumeIsolated {
      observeTask?.cancel()
    }
  }
}
