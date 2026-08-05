/// Debounce and dismiss/re-arm discipline for §12.3's mismatch warning,
/// built on `CameraMismatchClassifier`'s pure per-snapshot classification
/// (see that file's doc comment for the classification rule itself and the
/// corrected heuristic's reasoning). No `AVFoundation`/`CoreMediaIO`
/// import — same "fully unit-testable without a live camera" shape as
/// `CameraReminderStateMachine`/`CameraGatingStateMachine`, and modeled on
/// `CameraReminderStateMachine` specifically, per the PR brief.
///
/// ## A persistent, level-triggered notice — not a one-shot event
///
/// `CameraReminderStateMachine` fires a single spoken utterance on a rising
/// edge and then goes quiet. This machine is different in kind: §12.3's
/// warning is "informational and dismissible," a standing VoiceOver-readable
/// notice in the Setup window, not an utterance. So `update` does not return
/// a fire-once `Outcome` — it returns the CURRENT state to display, on every
/// call, computed fresh from three independent inputs: the debounced
/// classification, whether the user has dismissed the current episode, and
/// whether the feature is enabled. There is no analogue of `.pending`/
/// `.speakNow`; there is only "show this now" or "show nothing now."
///
/// ## Debounce (reuses `Config.Camera.busyDebounceMs` — §0: no second
/// debounce for one underlying signal)
///
/// Stage 1 is the same coalescing debounce `CameraGatingStateMachine` and
/// `CameraReminderStateMachine` both use, generalized from a `Bool` to
/// `CameraMismatchClassification`: a new classification must hold steady
/// for `debounceMs` before it becomes the debounced value callers see. This
/// exists for the same reason it exists everywhere else in this file's
/// family — a device flapping in and out of `.running` (a marginal USB
/// webcam, a background app briefly polling a camera) must not flicker the
/// notice on and off.
///
/// ## What "dismissed" means, and what "clears" means for re-arming
///
/// The PR brief asks this machine to apply "the same edge/consume
/// discipline the reminder uses... a dismissed warning must not immediately
/// reappear. It re-arms only when the condition clears and recurs." Concretely:
///
/// - `dismiss()` suppresses the notice for the CURRENT episode — the run of
///   debounced classifications since the last time the debounced value was
///   `.clear`. It does not matter whether the classification flips between
///   `.mismatch` and `.unreliable` within that episode (e.g. a second camera
///   drops from `.running` to a failed read and back); as long as the
///   debounced value never returns to `.clear`, the episode — and the
///   dismissal — continues.
/// - **"Clears" means the debounced classification settles on `.clear`.**
///   That is the one and only re-arm point: the moment it happens, the
///   dismissal is forgotten, so the NEXT settle into `.mismatch` or
///   `.unreliable` is a fresh episode and shows again even though the user
///   never took any action to un-dismiss it. This mirrors the reminder's
///   "only a fresh false→true transition can fire again" rule, adapted from
///   a rising edge to a persistent notice's re-entry into a problem state.
/// - Calling `dismiss()` while nothing is currently showing (debounced
///   classification already `.clear`) is a TRUE no-op — see `dismiss()`'s
///   own doc comment for why it is guarded explicitly rather than relying
///   on the settle-into-`.clear` reset, which cannot fire from a state that
///   is already `.clear`.
///
/// ## Why `isEnabled` is a live gate, not part of the episode
///
/// Unlike the reminder's `isEnabled` (one of three gates that, if it blocks
/// a settle-time or deadline-time evaluation, consumes that whole episode —
/// see that machine's doc comment), `isEnabled` here is evaluated fresh on
/// every `update` call and does not participate in episode/dismissal
/// bookkeeping at all. This is a deliberate difference, not an oversight:
/// the reminder is a one-shot utterance where "retroactively speaking a
/// stale fact" is actively wrong, so a blocked evaluation must permanently
/// consume that edge. This machine's output is a level-triggered status
/// display — toggling `Config.Camera.cameraMismatchWarningEnabled` off and
/// back on mid-episode should show the CURRENT truth immediately once
/// re-enabled, the same way any other status row would, not stay
/// permanently blind to an episode that started while the toggle was off.
/// `dismiss()` alone carries memory across calls; `isEnabled` never does.
public struct CameraMismatchStateMachine: Sendable {
  /// Which kind of notice is active — the two non-`.clear`
  /// `CameraMismatchClassification` cases, narrowed to exclude `.clear`
  /// (which never has a notice by definition) so `Outcome.notice` cannot be
  /// constructed with a value that would make no sense to display.
  public enum Kind: Sendable, Equatable {
    case mismatch
    case unreliable
  }

  /// What a caller should display right now — recomputed on every `update`
  /// call, not a discrete event. See this type's doc comment for why this
  /// shape differs from `CameraReminderStateMachine.Outcome`.
  public enum Outcome: Sendable, Equatable {
    /// Nothing to show: the debounced classification is `.clear`, the
    /// current episode has been dismissed, or the feature is disabled.
    case noNotice
    /// Show this notice. VoiceOver text/dismiss-button wiring is an
    /// App-side concern (`CameraMismatchController`); this only says which
    /// of the two closed-vocabulary situations applies.
    case notice(Kind)
  }

  private let debounceSeconds: Double

  private var debouncedClassification: CameraMismatchClassification = .clear
  private var pendingClassification: CameraMismatchClassification?
  private var pendingSince: Double?
  private var isDismissed = false

  /// - Parameter debounceMs: `Config.Camera.busyDebounceMs` — the same
  ///   field `CameraGatingStateMachine`/`CameraReminderStateMachine` read
  ///   (§0: do not invent a second debounce for the same underlying
  ///   per-device signal).
  public init(debounceMs: Int) {
    self.debounceSeconds = Double(debounceMs) / 1000
  }

  /// Feeds one new classification and returns the current display state.
  /// `now` is caller-supplied monotonic seconds, same contract as every
  /// other machine in this file's family — production callers derive it
  /// from `ContinuousClock`; tests pass a fully controlled fake clock.
  @discardableResult
  public mutating func update(
    classification: CameraMismatchClassification,
    isEnabled: Bool,
    now: Double
  ) -> Outcome {
    advanceDebounce(classification: classification, now: now)
    return currentOutcome(isEnabled: isEnabled)
  }

  /// Suppresses the notice for the current episode. See this type's doc
  /// comment ("What 'dismissed' means") for exactly when it re-arms.
  ///
  /// Guarded by `debouncedClassification != .clear` so this is a TRUE no-op
  /// when called with nothing active — not merely one that "does not
  /// currently show anything," but one that leaves no trace at all. Without
  /// this guard, calling `dismiss()` while already `.clear` would set
  /// `isDismissed` and then never clear it (that only happens when a settle
  /// transitions INTO `.clear`, which cannot happen from a state that is
  /// already `.clear`), permanently suppressing the NEXT genuine episode —
  /// exactly the "immediately reappear" bug this type exists to prevent,
  /// just aimed at the wrong episode. In practice the caller (`SetupWindowView`'s
  /// dismiss button) only exists while a notice is already showing, so this
  /// guard is a correctness backstop for the type's own logical consistency
  /// more than a case real UI code hits.
  public mutating func dismiss() {
    guard debouncedClassification != .clear else { return }
    isDismissed = true
  }

  /// The same coalescing-debounce shape `CameraGatingStateMachine.update`
  /// uses, generalized to a 3-case `Equatable` value instead of `Bool`. On
  /// settling to `.clear`, resets `isDismissed` — this is the re-arm point
  /// this type's doc comment describes.
  private mutating func advanceDebounce(
    classification: CameraMismatchClassification,
    now: Double
  ) {
    if classification != (pendingClassification ?? debouncedClassification) {
      pendingClassification = classification
      pendingSince = now
    }

    guard
      let pendingClassification, let pendingSince,
      pendingClassification != debouncedClassification,
      now - pendingSince >= debounceSeconds
    else {
      return
    }

    debouncedClassification = pendingClassification
    self.pendingClassification = nil
    self.pendingSince = nil

    if debouncedClassification == .clear {
      isDismissed = false
    }
  }

  private func currentOutcome(isEnabled: Bool) -> Outcome {
    guard isEnabled, !isDismissed, let kind = Kind(debouncedClassification) else {
      return .noNotice
    }
    return .notice(kind)
  }
}

extension CameraMismatchStateMachine.Kind {
  /// `nil` for `.clear` — the one classification that never has a notice.
  fileprivate init?(_ classification: CameraMismatchClassification) {
    switch classification {
    case .clear: return nil
    case .mismatch: self = .mismatch
    case .unreliable: self = .unreliable
    }
  }
}
