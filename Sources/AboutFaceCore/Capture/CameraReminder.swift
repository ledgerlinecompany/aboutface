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
/// decide WHETHER this particular rising edge is allowed to produce it. One
/// `Bool` return, not an event enum/array — there is only ever one kind of
/// event.
///
/// Still modeled on `CameraGatingStateMachine` in the ways that count: no
/// `AVFoundation`/`CoreMediaIO` import (fully unit-testable without a live
/// camera), a caller-supplied monotonic `now: Double` rather than reading
/// wall-clock time itself, and the exact same coalescing-debounce shape
/// reusing `Config.Camera.busyDebounceMs` (§0: do not invent a second
/// debounce for the same underlying signal).
///
/// ## The three gates, and why they are all evaluated at edge-settle time
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
/// All three are read exactly once, at the instant a debounced false→true
/// transition settles — not polled continuously, and not re-checked later.
/// This is a deliberate judgment call with one consistent rule behind it,
/// spelled out because the PR brief calls out the silence case explicitly
/// as needing a documented decision: **a gate that blocks the edge consumes
/// it.** Once a rising edge has settled — fired or suppressed — the machine
/// will not evaluate that same busy-stays-true episode again until the
/// signal returns to false and rises again. Concretely:
///
/// - Silenced when the edge settles → suppressed. Un-silencing five seconds
///   later does **not** retroactively speak the reminder, even though the
///   camera is still busy. The moment to say "camera in use" has passed;
///   speaking it well after the fact, disconnected from the edge that
///   actually happened, would be a non-sequitur ("why is it telling me this
///   now, nothing just changed") rather than a timely reminder.
/// - Capturing when the edge settles → suppressed, for the SAME reason, not
///   a different one. This matters because it is the common case, not an
///   edge case: About Face capturing is exactly what makes the raw signal
///   read true in the first place (starting Setup or Monitor while idle IS
///   a false→true transition of `kCMIODevicePropertyDeviceIsRunningSomewhere`).
///   Stopping Monitor later, with the signal still true because a real
///   conferencing app is also on the call, must not retroactively fire
///   either — same rule, applied to the constraint that is actually load-
///   bearing here.
/// - Disabled when the edge settles → suppressed, same rule again, for
///   consistency: flipping `Config.Camera.monitorReminderEnabled` on mid-
///   episode does not reach back and announce an edge that already passed.
///
/// The alternative — re-checking the gates continuously and firing the
/// instant all three become favorable, however long after the actual edge —
/// was rejected because it decouples the announcement from the event that
/// justifies it. A "rising edge" reminder that can fire on a falling
/// silence-toggle edge instead is not the feature §12.2 describes.
public struct CameraReminderStateMachine: Sendable {
  private let debounceSeconds: Double

  private var debouncedBusy = false
  private var pendingBusy: Bool?
  private var pendingSince: Double?

  /// - Parameter debounceMs: `Config.Camera.busyDebounceMs` — the SAME
  ///   debounce field `CameraGatingStateMachine` reads (§0: no second
  ///   debounce for one underlying signal), reused here for the reminder's
  ///   own edge detection.
  public init(debounceMs: Int) {
    self.debounceSeconds = Double(debounceMs) / 1000
  }

  /// Feeds one new observation and returns whether THIS call should cause
  /// the reminder to be spoken. `now` is caller-supplied monotonic seconds,
  /// same contract as `CameraGatingStateMachine.update` — production
  /// callers derive it from `ContinuousClock`; tests pass a fully
  /// controlled fake clock so debounce-timing assertions are exact rather
  /// than depending on real sleeps.
  ///
  /// Returns `true` at most once per false→true transition of the debounced
  /// signal — see this type's doc comment for the full rationale, including
  /// why a gate that blocks an edge does not get a second chance until the
  /// signal falls and rises again.
  @discardableResult
  public mutating func update(
    busy: Bool,
    isCapturing: Bool,
    isSilenced: Bool,
    isEnabled: Bool,
    now: Double
  ) -> Bool {
    if busy != (pendingBusy ?? debouncedBusy) {
      pendingBusy = busy
      pendingSince = now
    }

    guard
      let pendingBusy, let pendingSince,
      pendingBusy != debouncedBusy,
      now - pendingSince >= debounceSeconds
    else {
      return false
    }

    debouncedBusy = pendingBusy
    self.pendingBusy = nil
    self.pendingSince = nil

    // Falling edge: nothing to announce. The NEXT rising edge (a fresh
    // false→true transition, handled by the branch above on some later
    // call) is what re-arms the reminder — this is the "re-arms only after
    // the signal goes back to false" rule from the PR brief, and it falls
    // out of the debounce bookkeeping above for free: a settled `false`
    // baseline is exactly what makes a later `true` observation register as
    // a NEW pending transition rather than a no-op.
    guard debouncedBusy else { return false }

    // Rising edge, settled: this is the one moment the three gates are
    // consulted — see the type-level doc comment for why "at settle time,
    // once" is the rule rather than "whenever all three happen to be true."
    return isEnabled && !isCapturing && !isSilenced
  }
}
