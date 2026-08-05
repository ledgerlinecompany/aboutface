/// Debounce and the `isEnabled` gate for §12.5's app-side Center Stage
/// wiring, built on `CenterStageClassifier`'s pure per-reading classification
/// (see that file's doc comment for the classification rule, and for why
/// `.unknown` stays distinguishable from `.notActive`). No `AVFoundation`
/// import — fully unit-testable, same "no live camera needed" shape as
/// `CameraMismatchStateMachine`, which this type is modeled on per the PR
/// brief.
///
/// ## A live status read, not a dismissible notice
///
/// Unlike `CameraMismatchStateMachine`, this type has no `dismiss()`. §12.3's
/// warning is "informational and dismissible" because a false positive there
/// is a real, accepted cost the user might reasonably want to silence for a
/// while (see that type's doc comment). Center Stage awareness has no
/// equivalent: its Setup-window notice is a plain, always-current status
/// readout ("Center Stage is on" / "off" / "could not be determined"), the
/// same kind of thing `SetupWindowView`'s "State" row already is — there is
/// nothing here a user would ever want to dismiss for a while and have
/// reappear later, so no episode/dismiss bookkeeping exists to get right or
/// wrong.
///
/// ## Debounce (reuses `Config.Camera.busyDebounceMs` — §0: no second
/// debounce for one underlying signal)
///
/// Same coalescing debounce `CameraMismatchStateMachine`/
/// `CameraGatingStateMachine` all use, generalized to `CenterStageSignal`
/// instead of their own classification types: a new signal must hold steady
/// for `debounceMs` before it becomes the value callers see. This is the
/// house rule's hysteresis/dwell requirement (§4, §7) applied to this
/// signal — `isCenterStageActive` is Apple's own instance property, not
/// something this app controls, and nothing rules out a brief flap around a
/// format renegotiation or a Continuity Camera reconnect.
///
/// ## `isEnabled` is a live gate, not part of any episode
///
/// Same reasoning as `CameraMismatchStateMachine`'s own `isEnabled` (see
/// that type's doc comment, "Why `isEnabled` is a live gate"):
/// `Config.Camera.centerStageAwarenessEnabled` is read fresh on every
/// `update` call. Debounce keeps advancing underneath regardless of whether
/// the feature is enabled, so re-enabling shows the CURRENT truth
/// immediately rather than a value frozen from before the toggle.
public struct CenterStageStateMachine: Sendable {
  /// What to report right now — recomputed on every `update` call, not a
  /// discrete event. See this type's doc comment for why this shape (a
  /// level-triggered status) differs from a fire-once outcome.
  public enum Outcome: Sendable, Equatable {
    /// `Config.Camera.centerStageAwarenessEnabled == false` — nothing to
    /// show, the same "config-gated feature shows nothing while off" shape
    /// §12.3/§12.4's own master switches use.
    case disabled
    /// The debounced signal is `.active`.
    case active
    /// The debounced signal is `.notActive`.
    case notActive
    /// The debounced signal is `.unknown` (the device could not be
    /// resolved). Kept distinguishable from `.notActive` all the way out to
    /// the caller — see `CenterStageClassifier`'s doc comment.
    case unknown
  }

  private let debounceSeconds: Double

  private var debouncedSignal: CenterStageSignal = .notActive
  private var pendingSignal: CenterStageSignal?
  private var pendingSince: Double?

  /// - Parameter debounceMs: `Config.Camera.busyDebounceMs` — the same field
  ///   every other machine in this file's family reads (§0: do not invent a
  ///   second debounce for the same underlying per-device signal).
  public init(debounceMs: Int) {
    self.debounceSeconds = Double(debounceMs) / 1000
  }

  /// Feeds one new `CenterStageSignal` and returns the current display
  /// state. `now` is caller-supplied monotonic seconds, same contract as
  /// every other machine in this file's family — production callers derive
  /// it from `ContinuousClock`; tests pass a fully controlled fake clock.
  @discardableResult
  public mutating func update(
    signal: CenterStageSignal,
    isEnabled: Bool,
    now: Double
  ) -> Outcome {
    advanceDebounce(signal: signal, now: now)
    guard isEnabled else { return .disabled }
    return Outcome(debouncedSignal)
  }

  /// Whether `FeedbackRouter.setCenterStageActive(_:at:)` should be told
  /// Center Stage is active right now — `true` only for a settled `.active`
  /// signal. Both `.notActive` and `.unknown` resolve to `false`: the router
  /// only accepts a `Bool`, and "not confidently active" is the one safe
  /// reading for either case (see `CenterStageClassifier`'s doc comment —
  /// silently reporting automatic framing that is not, in fact, happening is
  /// the worse direction to be wrong in). Deliberately NOT gated on
  /// `isEnabled` here: `FeedbackRouter.setCenterStageActive` already forces
  /// `centerStageActive` to `false` unconditionally when
  /// `centerStageAwarenessEnabled` is off (see that method's doc comment),
  /// so a caller may pass this value to the router regardless of the config
  /// flag with no double-gating needed.
  public var routerActive: Bool {
    debouncedSignal == .active
  }

  /// Same coalescing-debounce shape `CameraMismatchStateMachine
  /// .advanceDebounce` uses, over `CenterStageSignal` instead of
  /// `CameraMismatchClassification`.
  private mutating func advanceDebounce(signal: CenterStageSignal, now: Double) {
    if signal != (pendingSignal ?? debouncedSignal) {
      pendingSignal = signal
      pendingSince = now
    }

    guard
      let pendingSignal, let pendingSince,
      pendingSignal != debouncedSignal,
      now - pendingSince >= debounceSeconds
    else {
      return
    }

    debouncedSignal = pendingSignal
    self.pendingSignal = nil
    self.pendingSince = nil
  }
}

extension CenterStageStateMachine.Outcome {
  fileprivate init(_ signal: CenterStageSignal) {
    switch signal {
    case .active: self = .active
    case .notActive: self = .notActive
    case .unknown: self = .unknown
    }
  }
}
