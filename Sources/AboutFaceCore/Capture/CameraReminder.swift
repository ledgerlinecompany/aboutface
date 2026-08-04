/// Pure decision logic for §12.2/§16.4's rising-edge camera-in-use
/// **reminder** — the maintainer's settled direction (2026-08-03/04),
/// replacing the never-shipped camera-gated auto-activation
/// `CameraGatingStateMachine` implements. Read §12.2's "Proposed direction"
/// passage and §16.4 point 4 before touching this file; both are the
/// authoritative record of WHY a reminder rather than an activation trigger.
///
/// ## Why this is a separate, simpler type rather than a `CameraGating.swift`
/// addition
///
/// §12.2 says it plainly: "a reminder's decision logic — arm while idle,
/// fire once on the rising edge — is a different and likely simpler
/// question" than `CameraGatingStateMachine`'s off/setup/monitor three-way
/// table. That table exists to decide WHICH mode transition to make;
/// reminder has exactly one output ("speak the reminder") and only needs to
/// decide WHETHER this particular rising edge is allowed to produce it.
///
/// Still modeled on `CameraGatingStateMachine` in the ways that count: no
/// `AVFoundation`/`CoreMediaIO` import (fully unit-testable without a live
/// camera), a caller-supplied monotonic `now: Double` rather than reading
/// wall-clock time itself, and the exact same coalescing-debounce shape
/// reusing `Config.Camera.busyDebounceMs` (§0: do not invent a second
/// debounce for the same underlying signal).
///
/// ## The three settle-time gates, and the field finding that added a delay
///
/// `update(busy:isCapturing:isSilenced:isEnabled:now:)` takes three
/// independent booleans besides the raw signal:
///
/// - `isCapturing` — the hard constraint from `kCMIODevicePropertyDeviceIsRunningSomewhere`'s
///   semantics (§12.2): it reads true when **any** process streams,
///   including About Face itself, so a reminder that could fire while
///   Setup or Monitor is running would announce itself the instant capture
///   starts. Callers pass `PipelineModel.isRunning` — true for either mode,
///   since either opens the camera.
/// - `isSilenced` — §7.5 manual silence. "If the user has silenced the app,
///   this stays silent. No exceptions" (PR brief).
/// - `isEnabled` — `Config.Camera.monitorReminderEnabled` (§0/§11: every
///   tunable lives in `Config`).
///
/// Originally all three were read exactly once, at the instant a debounced
/// false→true transition settled, and the reminder spoke immediately. The
/// maintainer's field finding (2026-08-04, §12.2) added
/// `Config.Camera.reminderDelayMs` (default 1500ms) between settle and
/// speech, because a call starting is itself an audio-busy moment — join
/// tones, the app's own chime, people saying hello — and a reminder landing
/// in the middle of that is easy to miss or talk over.
///
/// That delay changes what "read exactly once" has to mean. The phrase is
/// "Camera in use. Monitor is off." — it asserts a fact about the app's OWN
/// state, and across 1.5 real seconds that fact can stop being true. The
/// common case, not an edge case, is the user hearing the join sound,
/// reaching for the Monitor hotkey immediately, and the delay elapsing
/// *after* they've already done the thing the reminder exists to prompt.
/// Speaking a stale "Monitor is off" into that moment is worse than saying
/// nothing — it is actively wrong, not just unhelpful. So the gates (plus
/// the busy signal itself) are read a SECOND time, fresh, at the end of the
/// delay, and only fire if they still all hold then. The edge-time read
/// decides whether to ARM the delay at all; the deadline-time read decides
/// whether to actually SPEAK.
///
/// ## "A gate that blocks the edge consumes it" — now at two moments
///
/// This is the one consistent rule behind both evaluation points, spelled
/// out because the PR brief calls out the silence case explicitly as
/// needing a documented decision: **a gate that blocks a settle-time
/// evaluation consumes the episode.** Whether the block happens at edge-
/// settle time (never armed) or at deadline time (armed, then dropped), the
/// machine will not evaluate that same busy-stays-true episode again until
/// the signal returns to false and rises again. Concretely, at EITHER
/// evaluation point:
///
/// - Silenced → suppressed. Un-silencing after the fact — five seconds
///   after edge-settle, or one second after a deadline-time drop — does
///   **not** retroactively speak the reminder. The moment to say "camera in
///   use" has passed; speaking it well after the fact, disconnected from
///   the edge that actually happened, would be a non-sequitur ("why is it
///   telling me this now, nothing just changed") rather than a timely
///   reminder.
/// - Capturing → suppressed, for the SAME reason, not a different one. This
///   matters because it is the common case at edge-settle time (starting
///   Setup or Monitor while idle IS a false→true transition of
///   `kCMIODevicePropertyDeviceIsRunningSomewhere`) AND at deadline time
///   (the user hit the Monitor hotkey during the delay — see above). Either
///   way, once suppressed, it stays suppressed for this episode.
/// - Disabled → suppressed, same rule again, for consistency.
/// - Busy itself going false during the delay (a false start, a call that
///   ended instantly, a device flapping past the debounce) is the deadline-
///   time-only case with no edge-settle-time analogue: there is nothing
///   left to remind about, so the pending fire is dropped the moment the
///   debounced signal itself settles back to `false` — see `update`'s
///   falling-edge branch.
///
/// The alternative — re-checking the gates continuously and firing the
/// instant all three become favorable, however long after the actual edge
/// or the deadline — was rejected for the reason above: it decouples the
/// announcement from the event that justifies it. A "rising edge" reminder
/// that can fire on a favorable-gate edge well after either the busy signal
/// or the delay settled is not the feature §12.2 describes.
public struct CameraReminderStateMachine: Sendable {
  /// What a caller should do with the result of one `update` call. Not a
  /// `Bool` — `Bool` can only mean one thing, and this machine has THREE
  /// meaningfully different answers: nothing changed, speak right now, or
  /// something is scheduled and the caller must arrange a future call to
  /// find out what happens to it. Smuggling "scheduled" through `true`
  /// would make callers speak too early; smuggling it through `false` would
  /// make them stop ticking a reminder that is still pending.
  public enum Outcome: Sendable, Equatable {
    /// No reminder is in flight and none should be spoken as a result of
    /// this call — either nothing changed, or a pending reminder was just
    /// dropped by a gate failing at deadline time.
    case nothing

    /// Speak the reminder now. Returned only from the call whose `now`
    /// reaches or passes a previously-armed deadline AND all four checks
    /// (busy, capturing, silenced, enabled) still hold at that instant.
    case speakNow

    /// A rising edge settled and passed the settle-time gates; the
    /// reminder is scheduled for `deadline` (same monotonic clock as the
    /// `now` passed into `update`). The caller MUST arrange to call
    /// `update` again at or after `deadline` — with fresh gate values, not
    /// cached ones — or the reminder will never resolve to `.speakNow` or
    /// be dropped; see this type's doc comment for why a second read is
    /// required at all.
    case pending(deadline: Double)
  }

  private let debounceSeconds: Double
  private let delaySeconds: Double

  private var debouncedBusy = false
  private var pendingBusy: Bool?
  private var pendingSince: Double?

  /// Deadline (same monotonic clock as `now`) of a reminder armed by a
  /// settled rising edge that passed its edge-time gates, and not yet
  /// resolved to a fire-or-drop decision. `nil` whenever nothing is
  /// in flight — cleared the instant it resolves either way, and cleared
  /// early if the busy signal itself falls before the deadline arrives
  /// (see `update`'s falling-edge branch).
  private var pendingFireDeadline: Double?

  /// - Parameters:
  ///   - debounceMs: `Config.Camera.busyDebounceMs` — the SAME debounce
  ///     field `CameraGatingStateMachine` reads (§0: no second debounce for
  ///     one underlying signal), reused here for the reminder's own edge
  ///     detection.
  ///   - delayMs: `Config.Camera.reminderDelayMs` — the field-finding delay
  ///     between a settled rising edge and speech (this type's doc
  ///     comment). Distinct from `debounceMs`: debounce decides whether an
  ///     edge is real; this delay decides when a real edge's reminder is
  ///     actually spoken.
  public init(debounceMs: Int, delayMs: Int) {
    self.debounceSeconds = Double(debounceMs) / 1000
    self.delaySeconds = Double(delayMs) / 1000
  }

  /// Feeds one new observation and returns what the caller should do as a
  /// result — see `Outcome`. `now` is caller-supplied monotonic seconds,
  /// same contract as `CameraGatingStateMachine.update` — production
  /// callers derive it from `ContinuousClock`; tests pass a fully
  /// controlled fake clock so debounce- and delay-timing assertions are
  /// exact rather than depending on real sleeps.
  ///
  /// Every call re-runs both stages: first the busy-signal debounce (as
  /// before), then — if a fire is currently pending — the deadline check.
  /// A single call can legitimately do both (e.g. a falling edge settling
  /// in the same call that would otherwise have reached the deadline);
  /// order matters, and the busy-signal stage always runs first, so a
  /// falling edge that settles this instant correctly drops a fire that
  /// would otherwise have resolved this same instant.
  @discardableResult
  public mutating func update(
    busy: Bool,
    isCapturing: Bool,
    isSilenced: Bool,
    isEnabled: Bool,
    now: Double
  ) -> Outcome {
    advanceBusyDebounce(
      busy: busy, isCapturing: isCapturing, isSilenced: isSilenced,
      isEnabled: isEnabled, now: now)
    return resolvePendingFire(
      isCapturing: isCapturing, isSilenced: isSilenced,
      isEnabled: isEnabled, now: now)
  }

  /// Stage 1: the same coalescing debounce `CameraGatingStateMachine` uses,
  /// applied to the raw busy signal. On a settled transition, either arms a
  /// pending fire (rising edge, edge-time gates favorable), consumes the
  /// edge silently (rising edge, a gate failed), or clears any pending fire
  /// that a prior rising edge armed (falling edge — see this type's doc
  /// comment: nothing is left to remind about once busy itself goes false).
  private mutating func advanceBusyDebounce(
    busy: Bool,
    isCapturing: Bool,
    isSilenced: Bool,
    isEnabled: Bool,
    now: Double
  ) {
    if busy != (pendingBusy ?? debouncedBusy) {
      pendingBusy = busy
      pendingSince = now
    }

    guard
      let pendingBusy, let pendingSince,
      pendingBusy != debouncedBusy,
      now - pendingSince >= debounceSeconds
    else {
      return
    }

    debouncedBusy = pendingBusy
    self.pendingBusy = nil
    self.pendingSince = nil

    // Falling edge: nothing to announce, and nothing left to wait for — a
    // fire armed by the episode that just ended is moot the moment the
    // signal itself goes idle. The NEXT rising edge (a fresh false→true
    // transition, handled by the branch below on some later call) is what
    // re-arms the reminder.
    guard debouncedBusy else {
      pendingFireDeadline = nil
      return
    }

    // Rising edge, settled: the first of the two gate evaluations — see
    // the type-level doc comment for why "at settle time" is still the
    // right moment to decide whether to ARM at all, even though it is no
    // longer the moment that decides whether to SPEAK.
    if isEnabled && !isCapturing && !isSilenced {
      pendingFireDeadline = now + delaySeconds
    } else {
      pendingFireDeadline = nil
    }
  }

  /// Stage 2: if a fire is pending, either report it is still pending
  /// (deadline not yet reached), or — once `now` reaches the deadline —
  /// re-validate all four checks fresh and resolve to `.speakNow` or
  /// `.nothing`. This is the second gate evaluation the field finding
  /// added; see the type doc comment for why re-checking `debouncedBusy`
  /// here (not just at fall-settle time in stage 1) is required rather
  /// than redundant — a delay-elapsed call can be the very first call since
  /// the fall happened, if nothing else changed in between.
  private mutating func resolvePendingFire(
    isCapturing: Bool,
    isSilenced: Bool,
    isEnabled: Bool,
    now: Double
  ) -> Outcome {
    guard let deadline = pendingFireDeadline else { return .nothing }
    guard now >= deadline else { return .pending(deadline: deadline) }

    pendingFireDeadline = nil
    guard debouncedBusy, isEnabled, !isCapturing, !isSilenced else {
      return .nothing
    }
    return .speakNow
  }
}
