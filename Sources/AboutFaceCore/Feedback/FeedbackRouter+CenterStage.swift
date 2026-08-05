/// §12.5 Center Stage awareness — the app-facing entry point that feeds
/// `FeedbackRouter.centerStageActive` (declared in `FeedbackRouter.swift`
/// alongside every other piece of router state) from the app's own
/// `CenterStageReader` polling. Split into its own file for the same
/// file-size reason `FeedbackRouter+GazeTrim.swift`/`+GoodZoneAdvisories
/// .swift` give for their own splits — `FeedbackRouter.swift` was already
/// close to SwiftLint's `file_length` ceiling before this feature, and this
/// is a self-contained addition, not a modification of what's already
/// there.
///
/// **This PR does not include the app-side polling that calls this method.**
/// §12.5's own status block (`docs/spec.md`) records that the monitor/
/// controller wiring — something that actually watches
/// `CenterStageReading.automaticFramingInEffect` on a timer and calls this —
/// is a following PR's scope. This file is the core, headless, unit-testable
/// half: given a caller that already knows the current reading, this is
/// what `FeedbackRouter` does with it.
extension FeedbackRouter {
  /// Updates §12.5's Center Stage awareness state and speaks the
  /// rising/falling-edge notice exactly once per transition.
  ///
  /// ## Time is injected, always
  ///
  /// Same rule as `ingest(_:at:)` (see `FeedbackRouter.swift`'s type-level
  /// doc comment): `time` comes from the caller, never `ContinuousClock
  /// .now` read internally, so a test can drive this deterministically
  /// alongside a scripted `ingest` sequence.
  ///
  /// ## The edge latch
  ///
  /// `centerStageActive` IS the latch — this method only ever speaks when
  /// `active` differs from the CURRENTLY STORED value, so holding either
  /// state for many consecutive calls (the realistic shape of a poller
  /// calling this every tick) produces at most one utterance per genuine
  /// transition, never one per call.
  ///
  /// ## Gated on `config.camera.centerStageAwarenessEnabled`, structurally
  ///
  /// When the config flag is off, this method forces `centerStageActive` to
  /// `false` UNCONDITIONALLY — not just "skip the notice" — so every
  /// downstream suppression point (the continuous beacon, spoken framing,
  /// good-zone entry chime) reads `false` and behaves exactly as if Center
  /// Stage were never active, without any of those three call sites having
  /// to separately consult the config flag themselves. This mirrors
  /// `monitorReminderEnabled`'s own precedent (`Config.Camera`'s doc
  /// comment): "flipping this off mid-episode does not retroactively
  /// announce a suppressed edge" — if the caller had `active: true` in
  /// flight when the flag was disabled, the falling-edge phrase is not
  /// spoken either; disabling the awareness feature is not itself a Center
  /// Stage transition worth announcing.
  ///
  /// ## Why `fire`, not a direct `speech.speak` call
  ///
  /// Routing through `fire(event:phrase:key:at:bypassRateLimit:)` is
  /// deliberate, not incidental: `fire` is the ONE call site every
  /// announcement in this router goes through, and it already enforces both
  /// §7.5 manual silence (`isSilenced`) and §7.3's rung-3 `userLikelyAway`
  /// STOP — see that method's own doc comment. Reusing it means this notice
  /// automatically inherits both gates for free, in particular "never
  /// announce Center Stage to an empty desk": a Center Stage toggle that
  /// happens to arrive while the router has already concluded nobody is at
  /// the camera (§7.3's 30s STOP) produces zero renderer calls, exactly like
  /// every other announcement does during that state. `bypassRateLimit:
  /// true` for the same reason the heartbeat/face-lost ladder use it — this
  /// is safety/orientation-relevant state the user needs to hear regardless
  /// of whatever unrelated condition just consumed the §5.2 Monitor
  /// rate-limit budget, not discretionary chatter that budget is meant to
  /// ration. `key: nil` since this never participates in per-condition rate
  /// limiting (irrelevant given the bypass, but keeps the call site honest
  /// about what it's for).
  public func setCenterStageActive(_ active: Bool, at time: ContinuousClock.Instant) async {
    guard config.camera.centerStageAwarenessEnabled else {
      centerStageActive = false
      return
    }
    guard active != centerStageActive else { return }
    centerStageActive = active
    let phrase = active ? Lexicon.State.centerStageOn : Lexicon.State.centerStageOff
    await fire(event: nil, phrase: phrase, key: nil, at: time, bypassRateLimit: true)
  }
}
