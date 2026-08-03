import AboutFaceCore
import SwiftUI

/// `setMode(_:)` (§5, §13 Phase 4): switches between Setup and Monitor on an
/// already-constructed `PipelineModel`, restarting capture at the new mode's
/// format and pushing the mode through to `FeedbackRouter`. Split out of
/// `PipelineModel.swift` purely to keep each file a manageable size (see
/// that file's doc comment); everything here is still `PipelineModel`'s own
/// implementation, not a separate public surface.
///
/// This PR is the mode PLUMBING only — nothing calls `setMode` yet in normal
/// use (task brief: "a SEPARATE later PR wires the triggers"). The debug
/// panel's mode control (`DebugPanelView+Mode.swift`) is the only caller
/// today, alongside tests.
extension PipelineModel {

  /// The debug panel's mode `Picker` binds through `FeedbackMode`'s raw
  /// (`String`) value rather than the enum itself — same reasoning as
  /// `PipelineModel+Config.swift`'s `rawValueBinding(_:)` doc comment:
  /// SwiftUI's `Picker(selection:)` requires `Hashable`, and `FeedbackMode`
  /// (declared `Sendable, Equatable, CaseIterable`, not `Hashable`) is an
  /// `AboutFaceCore` type this UI-only need doesn't justify changing. Not
  /// built on top of `rawValueBinding(_:)` itself: that helper is keyed by
  /// a `WritableKeyPath<Config, Value>` and writes go through
  /// `updateConfig(_:)` — `mode` is `PipelineModel` session state, not a
  /// `Config` field, and a write here needs to `await setMode(_:)`
  /// (restarting capture), not just assign a property.
  public var modeBinding: Binding<FeedbackMode.RawValue> {
    Binding(
      get: { self.mode.rawValue },
      set: { newRaw in
        guard let newMode = FeedbackMode(rawValue: newRaw) else { return }
        Task { await self.setMode(newMode) }
      }
    )
  }

  /// Switches to `newMode`, restarting the capture session at its format if
  /// the pipeline is currently running. No-ops if `newMode` already equals
  /// the CURRENT mode by the time this call actually runs (see the
  /// serialization doc comment below for why "current" can differ from what
  /// was true when the caller decided to call this).
  ///
  /// ## Trap (c): overlapping/re-entrant transitions
  ///
  /// `setMode` is `async` and restarts hardware (stops one
  /// `CameraCaptureSource`, starts another). Two calls in flight at once —
  /// a hotkey mashed twice, or a future gating event racing a manual
  /// toggle — must not leave two capture sessions running or the model
  /// believing it is in a mode it is not (task brief).
  ///
  /// `modeTransitionChain` makes every call wait for every earlier call to
  /// fully finish before its own transition body runs, without blocking the
  /// caller's ability to just `await setMode(_:)` normally: each call
  /// captures the CURRENT chain as `previous`, builds a new `Task` that
  /// awaits `previous` before doing anything else, publishes that new task
  /// as the chain for whoever calls next, and then awaits its own task. The
  /// two statements between capturing `previous` and awaiting the new task
  /// (`Task { ... }` construction and the `modeTransitionChain =` write) are
  /// synchronous — `setMode` cannot suspend between them — so there is no
  /// window for a third call to observe a torn chain. The net effect is a
  /// plain FIFO queue of transitions with no explicit lock/semaphore type
  /// needed, and no risk of two transition bodies running concurrently.
  public func setMode(_ newMode: FeedbackMode) async {
    let previous = modeTransitionChain
    let task = Task { @MainActor [weak self] in
      await previous.value
      guard let self else { return }
      await self.performModeTransition(to: newMode)
    }
    modeTransitionChain = task
    await task.value
  }

  /// The actual transition body — only ever runs one at a time, serialized
  /// by `setMode(_:)`'s task chain above.
  private func performModeTransition(to newMode: FeedbackMode) async {
    guard newMode != mode else { return }
    mode = newMode

    // §7.2/§7.3: changing `mode` mid-episode also changes the router's
    // N-frame confirmation threshold and face-lost earcon delay
    // (`FeedbackRouter.nFrameThreshold`/`faceLostEarconDelayMs`, both keyed
    // on `mode`). An in-progress confirmation streak or ladder timer is
    // measured against whichever threshold is live WHEN IT NEXT TICKS, not
    // the one that was live when it started. This is accepted rather than
    // "fixed" by, say, freezing thresholds for the rest of an episode:
    // §5.1→§5.2 mode switches are themselves rare, deliberate, user- or
    // gating-triggered events (not a per-frame thing), and a switch
    // mid-episode already means the user's context just changed (e.g. a
    // call started) — re-evaluating against the NEW mode's posture is the
    // more correct behavior, not a bug to route around.
    if let feedbackRouter {
      await feedbackRouter.setMode(newMode)
    }

    guard isRunning, let deviceID = selectedCameraID else { return }
    await restartCapture(deviceID: deviceID, for: newMode)
  }

  /// Stops the current capture source and starts a new one at `mode`'s
  /// format, REUSING the existing `AnalysisEngine` rather than constructing
  /// a fresh one.
  ///
  /// ## Trap (b): the learned pose baseline must survive a mode switch
  ///
  /// `AnalysisEngine` carries the §16.2 auto-learned three-axis pose
  /// baseline ("level" means the user's OWN resting tilt) plus its §4/§7
  /// smoothing/hysteresis state. `start()` constructs a fresh engine every
  /// time it runs — correct there, since a fresh `start()` IS a fresh
  /// session with nothing yet to preserve — but naively doing the same
  /// here would silently discard a baseline the user spent
  /// `Config.Gaze.baselineAdaptationSeconds` (default 45s) establishing on
  /// every Setup↔Monitor transition, and "Level." would start meaning
  /// something different mid-call. Checked (not assumed): `AnalysisEngine
  /// .stream(from:)` is a plain method with no single-shot state of its
  /// own — it builds a fresh `AsyncThrowingStream` over whatever `source`
  /// it is given, while `process(_:)`'s actor-isolated smoothing/baseline
  /// state (declared once, at the `AnalysisEngine` type level) lives
  /// independently of any particular stream or source. So calling
  /// `engine.stream(from:)` again on a NEW `CameraCaptureSource`, using the
  /// SAME engine instance, is fully supported and is exactly what preserves
  /// the baseline here.
  ///
  /// ## Trap (a): the macOS `sessionPreset`-before-`startRunning()` recipe
  ///
  /// `CameraCaptureSource.configureSession()`'s own doc comment has the
  /// full empirical story (PR #53): `device.activeFormat` does not survive
  /// `session.startRunning()` on macOS, so the working recipe is a concrete
  /// `sessionPreset` at configuration time plus frame durations set AFTER
  /// `startRunning()`. That recipe is unchanged by this PR — a brand new
  /// `CameraCaptureSource` is constructed here (same as `start()` does),
  /// which re-runs `configureSession()`/`start()` end to end for the new
  /// format. This is Monitor's 640×480@15 actually taking effect for the
  /// first time in the app (Setup's 1280×720 happened to already equal the
  /// `.high` preset on the reference hardware, which is what masked the bug
  /// in the first place, per that doc comment) — see this PR's report for
  /// how that was verified.
  private func restartCapture(deviceID: String, for newMode: FeedbackMode) async {
    guard let engine else { return }

    captureGeneration += 1
    consumeTask?.cancel()
    consumeTask = nil
    await captureSource?.stop()
    captureSource = nil

    let modeSettings = config.camera.settings(for: newMode)
    let source = CameraCaptureSource(
      deviceUniqueID: deviceID,
      width: modeSettings.width,
      height: modeSettings.height,
      frameRate: modeSettings.frameRate
    )

    do {
      try await source.start()
    } catch {
      captureErrorMessage = "Could not switch capture format: \(error)"
      isRunning = false
      return
    }

    captureSource = source
    captureFormat = SignalFormatter.CaptureFormatDescriptor(
      width: modeSettings.width, height: modeSettings.height, frameRate: modeSettings.frameRate)
    mirrorState = source.mirrorState

    beginConsuming(engine: engine, source: source, targetAnalysisHz: modeSettings.analysisHz)
  }

  /// Spawns the per-frame consume loop over `engine.stream(from:
  /// targetAnalysisHz:)` — shared by `start()` (`PipelineModel.swift`) and
  /// `restartCapture(deviceID:for:)` above, so both go through one path.
  ///
  /// `captureGeneration` (declared on `PipelineModel` itself, so both
  /// `start()`/`stop()` and this file can bump it) exists because
  /// `restartCapture` replaces `consumeTask` on an ALREADY-RUNNING
  /// pipeline: cancelling the outer `Task` only causes `engine.stream(from:
  /// )`'s underlying `AsyncThrowingStream` to finish (via `onTermination`)
  /// — the closure below keeps running past its `for try await` loop
  /// either way, down to `self.isRunning = false`. Without a guard, a
  /// superseded task finishing its unwind AFTER a new mode's capture has
  /// already started would stomp `isRunning`/`captureErrorMessage` with
  /// stale state — trap (c) again, one level down from the task-chain
  /// serialization above (that chain keeps two `setMode` calls from
  /// running concurrently; this guards the OLD consume task's own tail from
  /// a transition it no longer represents). Comparing the captured
  /// `generation` against the current `captureGeneration` before writing
  /// either property makes a superseded task's tail a no-op.
  func beginConsuming(
    engine: AnalysisEngine,
    source: CameraCaptureSource,
    targetAnalysisHz: Double?
  ) {
    captureGeneration += 1
    let generation = captureGeneration
    // Not set here unconditionally: `start()` (`PipelineModel.swift`) sets
    // `isRunning = true` itself, synchronously, right after capture starts
    // and before this is called — restarting from `restartCapture(deviceID
    // :for:)` above only runs when `isRunning` is already `true` (its own
    // guard). Setting it again here would be harmless but redundant; not
    // doing so keeps this one property's writes in one obvious place per
    // call path.
    consumeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        for try await item in engine.stream(from: source, targetAnalysisHz: targetAnalysisHz) {
          self.ingest(item)
          await self.feedFeedbackChain(item)
        }
      } catch {
        if self.captureGeneration == generation {
          self.captureErrorMessage = "Capture stopped: \(error)"
        }
      }
      if self.captureGeneration == generation {
        self.isRunning = false
      }
    }
  }
}
