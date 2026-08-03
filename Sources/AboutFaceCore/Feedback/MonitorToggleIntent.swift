/// §8's ⌘⌃⇧M "Monitor mode toggle" (and the §16.4 `MenuBarExtra`'s own
/// toggle control) reduced to a pure decision over the two pieces of state
/// that determine it: whether the pipeline is currently running, and which
/// mode it is in. Factored out of `App/`'s `PipelineModel` so this decision
/// is unit-testable without `AVFoundation` (CLAUDE.md: "keep logic in
/// `AboutFaceCore`, keep `App/` thin" — `PipelineModel.toggleMonitor()`
/// only executes whichever case this returns, it does not re-derive it).
///
/// Deliberately a THREE-way decision, not a plain boolean flip: "toggle"
/// means different things depending on where the pipeline currently is, and
/// each of those needs a different `PipelineModel` call sequence (see
/// `PipelineModel+Mode.swift`'s `toggleMonitor()`):
///
/// - Not running at all: there is nothing to "switch" — Monitor has to be
///   started from scratch, at Monitor's own capture format.
/// - Running in Setup: the capture session is already live, so this is a
///   format-restart-in-place (`setMode(.monitor)`), not a fresh `start()` —
///   the same "no restart-from-scratch" shape `CameraGatingEvent.leaveSetup`
///   uses (`CameraGating.swift`), for the same reason: the pipeline is
///   already up, only its mode needs to change.
/// - Running in Monitor already: pressing the same key/button again means
///   "turn it off," not "do nothing" — an on/off toggle has to have an off
///   state reachable from its on state.
public enum MonitorToggleIntent: Sendable, Equatable {
  /// Pipeline is not running: start it directly in Monitor format.
  case startMonitor
  /// Pipeline is running in Setup: switch it to Monitor in place.
  case switchToMonitor
  /// Pipeline is running in Monitor already: stop it.
  case stop

  /// - Parameters:
  ///   - isRunning: `PipelineModel.isRunning`.
  ///   - mode: `PipelineModel.mode` — only meaningful while `isRunning` is
  ///     `true` (mirrors `CameraGatingMode`'s own "off means not running,
  ///     `mode` is otherwise irrelevant" shape in `CameraGating.swift`).
  public static func decide(isRunning: Bool, mode: FeedbackMode) -> MonitorToggleIntent {
    guard isRunning else { return .startMonitor }
    return mode == .monitor ? .stop : .switchToMonitor
  }
}
