/// The `FeedbackRouter` layer of §3.1's diagram: sits downstream of
/// `AnalysisEngine`, consumes its `EngineOutput` stream, and drives
/// `AudioRendering` + `SpeechRendering` (plus any registered
/// `EventSubscriber`s — see `EventSubscriber.swift`). This is where §7's
/// suppression and event state machine lives: `AnalysisEngine` produces
/// continuous, per-frame signals with "no notion of 'should this be
/// announced'" (its own doc comment); `FeedbackRouter` is that notion.
///
/// ## Time is injected, always
///
/// `ingest(_:at:)` takes an explicit `ContinuousClock.Instant` and this type
/// never reads `Date()`/`ContinuousClock.now` internally — every dwell
/// timer, rate limit, and heartbeat schedule is computed purely from the
/// sequence of `(EngineOutput, Instant)` pairs handed in. This is what makes
/// `FeedbackRouterDeterminismTests` meaningful (same script twice ⇒
/// identical renderer call logs) and what lets tests drive 800ms dwell
/// windows and 3-minute rate-limit windows without a single real
/// `Task.sleep`.
///
/// ## Two independent channels per frame
///
/// 1. **Continuous sonification** (§6.2) — `SonificationTarget` updates,
///    real-time, NOT gated by dwell (dwell gates "announcements" per §7.1;
///    the continuous tone is not an announcement, it's the fast ~100ms
///    correction loop §1 calls out as the whole point of sonification).
/// 2. **Discrete announcements** (§7) — earcons and speech, gated by §7.2's
///    N-frame suppression, then §7.1's 800ms dwell (or, for face-lost, its
///    own §7.3 ladder), then §5.2's per-mode rate limit.
///
/// See `FeedbackRouter+Condition.swift` for how a frame's `EngineOutput`
/// becomes a `DiscreteState`, `FeedbackRouter+Continuous.swift` for channel
/// 1 (`updateContinuousSonification`), and `FeedbackRouter+Announcements
/// .swift` for how a confirmed `DiscreteState` becomes (or doesn't become)
/// a call to `audio`/`speech`.
public actor FeedbackRouter {
  let audio: any AudioRendering
  let speech: any SpeechRendering
  var eventSubscribers: [any EventSubscriber] = []

  var config: Config
  var feedbackConfig: FeedbackConfig
  var mode: FeedbackMode

  var isSilenced = false
  /// Dedupe for the continuous channel's nil sends (see
  /// `updateContinuousSonification` in `FeedbackRouter+Continuous.swift`):
  /// `true` until the first active target goes out, so a stream that never
  /// had a face never spams `update(nil)`.
  var lastContinuousSendWasNil = true

  // MARK: - §7.2 N-frame + confirmed discrete state
  //
  // `pendingState`/`pendingStreak` track the RAW per-frame discrete state
  // (before N-frame confirmation). `confirmedState`/`confirmedStateStart`
  // is the state `FeedbackRouter` actually acts on — it only changes once
  // `pendingStreak` reaches the mode's N-frame threshold, and
  // `confirmedStateStart` is what every dwell/ladder timer below measures
  // elapsed time against. A blip that never reaches the threshold leaves
  // `confirmedState` (and any in-progress dwell/ladder timer on it)
  // completely untouched — see `FeedbackRouter+Condition.swift`'s doc
  // comment for why that is the desired suppression behavior, not a bug.
  var pendingState: DiscreteState?
  var pendingStreak = 0
  var confirmedState: DiscreteState?
  var confirmedStateStart: ContinuousClock.Instant?

  // MARK: - §7.1 generic dwell "already fired this episode" latch
  //
  // Shared by every `confirmedState` case EXCEPT face-lost, which tracks
  // its own ladder rung instead (below) because it has multiple timed rungs
  // rather than a single dwell-then-fire-once shape.
  var dwellFiredForCurrentEpisode = false

  // MARK: - §6.1 good-zone heartbeat scheduling
  var goodZoneConfirmedAt: ContinuousClock.Instant?
  var nextHeartbeatAt: ContinuousClock.Instant?

  // MARK: - §7.4 rung 6 gaze-off-in-good-zone advisory (app field finding,
  // 2026-08-02 — see `FeedbackCondition.gazeOff`'s doc comment)
  //
  // Runs entirely FROM WITHIN a confirmed `.goodZone` episode, parallel to
  // but independent of the pending/confirmed pair above (which now tracks
  // PLACEMENT only). Same two-stage shape as every other condition: a raw
  // per-frame gaze reading (`gazeOffPendingStreak`) must reach the mode's
  // N-frame threshold (§7.2) before `gazeOffConfirmedStart` is set, and only
  // then does an 800ms dwell clock (§7.1, `Config.dwellMs`) start counting
  // toward the single `lookAtCamera` announcement for the episode. See
  // `tickGoodZoneGaze(output:at:)` in `FeedbackRouter+Announcements.swift`.
  var gazeOffPendingStreak = 0
  var gazeOffConfirmedStart: ContinuousClock.Instant?
  var gazeAnnouncedForEpisode = false

  // MARK: - §4 extension, roll joins the gaze advisory (maintainer,
  // 2026-08-02: "Agreed, it's part of gaze")
  //
  // A SECOND in-zone advisory sub-machine, structurally identical to and
  // fully independent of the gaze-off one immediately above — its own
  // N-frame streak, its own dwell clock, its own once-per-episode latch.
  // Tracks `!FramingState.headLevel` instead of `!gazeOnCamera`. See
  // `tickGoodZoneRoll(output:at:)` in `FeedbackRouter+GoodZoneAdvisories.swift`.
  var headTiltPendingStreak = 0
  var headTiltConfirmedStart: ContinuousClock.Instant?
  var headTiltAnnouncedForEpisode = false

  // MARK: - Gaze trim (tuning round 5, maintainer-designed prototype,
  // default OFF — see `Config.AudioGazeTrim` and
  // `FeedbackRouter+GazeTrim.swift`). EMA state for the yaw/pitch
  // deviation smoothing, mirroring `AnalysisEngine`'s own
  // seed-with-first-sample convention: `nil` means "no prior sample,"
  // reset whenever `confirmedState` leaves `.goodZone` (see
  // `onConfirmedStateChanged`) so a fresh placement never inherits a
  // stale trend from an earlier episode.
  var smoothedYawDeviationDegrees: Float?
  var smoothedPitchDeviationDegrees: Float?

  // MARK: - §7.3 face-lost ladder
  //
  // `faceLostRung`: 0 = nothing fired yet, 1 = the §7.3 "1.5s" earcon has
  // fired, 2 = the "~5s" spoken "No face." has fired, 3 = the "~30s" STOP
  // has fired (silence + `userLikelyAway`, below). See
  // `tickFaceLostLadder(from:at:)` in `FeedbackRouter+FaceLost.swift` for
  // exactly where each rung's timer and side effect live.
  var faceLostRung = 0

  /// Whether the CURRENT face-lost episode has actually made a sound yet —
  /// tracked separately from `faceLostRung` because §12.5 made the two come
  /// apart. Under Center Stage the rung-1 earcon is suppressed while the rung
  /// itself still advances (rungs 2 and 3 must stay reachable — the 30s STOP
  /// is safety-critical and cannot be stranded), so "escalated" and "was
  /// audible" are no longer the same claim.
  ///
  /// Measured 2026-08-05: with Center Stage active and the user moving
  /// normally, 24.6% of frames returned no face at all, across 31 episodes in
  /// 30 seconds, the longest 2.5s — against 2.4% / 9 episodes / 169ms with
  /// Center Stage off and the same movement. Center Stage re-aims its crop
  /// and Vision loses the face while it pans. Every one of those episodes
  /// cleared rung 1's 500ms Setup threshold, so the user heard face-lost and
  /// face-reacquired earcons cycling continuously while sitting right there
  /// in front of a camera that was tracking them perfectly well.
  ///
  /// `handleFaceLostReacquisition` reads this (not `faceLostRung >= 1`) to
  /// decide whether recovery owes the user a `.faceReacquired` earcon: an
  /// episode nobody was ever told about needs no closure, and firing "you're
  /// back" for an absence never announced is how the second half of that
  /// cycling gets generated.
  var faceLostEpisodeWasAudible = false

  /// §7.3's rung-3 "STOP": becomes `true` the instant `faceLostRung`
  /// reaches 3 and stays `true` until the face is reacquired. Cleared by
  /// `handleFaceLostReacquisition` (`FeedbackRouter+FaceLost.swift`, called
  /// from `onConfirmedStateChanged` in `FeedbackRouter+Announcements.swift`)
  /// UNCONDITIONALLY — not only when a recovery announcement is actually
  /// owed. The "only escalated episodes get cleared" shape would be
  /// provably equivalent (rung 3 can only be reached after passing through
  /// rungs 1 and 2), but that equivalence is an invariant held by ARGUMENT,
  /// not enforced by the type system: if it is ever wrong — a future edit
  /// to the ladder, a bug elsewhere — the unconditional clear is the only
  /// thing standing between that bug and a router that goes permanently,
  /// silently mute with no path back to sound, ever. Clearing the flag a
  /// frame too eagerly costs nothing (it is already `false` in the
  /// overwhelmingly common case); failing to clear it costs total loss of
  /// function. See that method's own doc comment for the full reasoning.
  ///
  /// While `true`, both `fire(event:phrase:key:at:bypassRateLimit:)`
  /// (`FeedbackRouter+Announcements.swift`) and
  /// `updateContinuousSonification` (`FeedbackRouter+Continuous.swift`)
  /// short-circuit on it UNCONDITIONALLY, before either one even looks at
  /// `bypassRateLimit`/`isSilenced`. That has to be a blanket guard rather
  /// than, say, a check folded into the rate-limit branch: §7.3 frames the
  /// 30s stop as safety-critical ("the requirement an implementer will
  /// forget... a tool that nags at an empty chair for the rest of a
  /// meeting gets uninstalled"), and the heartbeat plus every face-lost
  /// ladder rung ALREADY bypass the ordinary rate limit for their own
  /// legitimate reasons — a guard hiding behind `bypassRateLimit` would do
  /// nothing to stop any of them, and a future bypassing condition would
  /// silently defeat rung 3 the same way. Deliberately independent of
  /// `isSilenced` (§7.5 manual silence): the two mechanisms happen to have
  /// the same audible effect (zero renderer calls) but are orthogonal in
  /// cause — one is the user's own hotkey, the other is the router's own
  /// inference that nobody is listening — so neither should read or set
  /// the other.
  var userLikelyAway = false

  // MARK: - §5.2 Monitor-mode rate limiting
  var lastAnnouncementAt: ContinuousClock.Instant?
  var lastAnnouncementAtByCondition: [FeedbackCondition: ContinuousClock.Instant] = [:]

  // MARK: - §12.5 Center Stage awareness
  //
  // The single source of truth every suppression point (the continuous
  // beacon in `FeedbackRouter+Continuous.swift`, spoken framing in
  // `FeedbackRouter+Announcements.swift`'s `announcementPayload(for:output:
  // centerStageActive:)`, and good-zone entry in `tickGoodZone`) reads.
  // Never written directly outside `setCenterStageActive(_:at:)`
  // (`FeedbackRouter+CenterStage.swift`) — that method IS the rising/
  // falling-edge latch (comparing the new value against this stored one is
  // what detects the edge), and it is also what forces this to `false`
  // whenever `config.camera.centerStageAwarenessEnabled` is off, so nothing
  // downstream needs its own copy of that config check. See that method's
  // doc comment for the full rationale.
  var centerStageActive = false

  // MARK: - §5.3 Query burst buffer + §8 repeat-last (FeedbackRouter+Query.swift)
  //
  // `recentOutputs` is a bounded ring of the most recently `ingest`ed
  // `EngineOutput`s, appended to unconditionally (even while `isSilenced` —
  // silence gates renderer calls only, §7.5, never the analysis bookkeeping
  // `ingest` otherwise keeps running) and trimmed to
  // `feedbackConfig.query.burstFrameCount`. See `recordForQuery(_:)`'s doc
  // comment in `FeedbackRouter+Query.swift` for why a Query "burst" is
  // defined this way rather than as a freshly-triggered capture.
  var recentOutputs: [EngineOutput] = []
  /// §8 repeat-last: the most recent phrase this router actually spoke
  /// through `fire(...)` — `nil` until the first one. `performQuery()`
  /// updates this too (bypassing `fire`), so repeating after a Query
  /// re-speaks the query summary. See `repeatLastAnnouncement()`.
  var lastSpokenPhrase: Lexicon.Phrase?

  public init(
    audio: any AudioRendering,
    speech: any SpeechRendering,
    config: Config = .defaults,
    feedbackConfig: FeedbackConfig? = nil,
    mode: FeedbackMode = .setup
  ) {
    self.audio = audio
    self.speech = speech
    self.config = config
    // `Config` carries the feedback tunables (§11: one Config struct); the
    // separate parameter exists only for tests that want to vary router
    // behavior without building a whole Config.
    self.feedbackConfig = feedbackConfig ?? config.feedback
    self.mode = mode
  }

  public func setMode(_ mode: FeedbackMode) {
    self.mode = mode
  }

  /// Actor-safe read of §7.3's rung-3 `userLikelyAway` flag, for future
  /// menu-bar/debug surfaces (§9's debug panel is the obvious eventual
  /// consumer — "is the user still even at the desk" is exactly the kind
  /// of state that panel exists to surface). Nothing calls this yet; that
  /// is deliberate — it exists now so a later observer can poll the
  /// CURRENT value without inventing its own way to reach into the actor.
  /// A caller that needs to react to the transition rather than poll it
  /// should use `EventSubscriber` (`EventSubscriber.swift`) instead — this
  /// accessor has no notion of "changed," only "is."
  public func isUserLikelyAway() -> Bool {
    userLikelyAway
  }

  public func updateConfig(_ config: Config) {
    self.config = config
  }

  public func updateFeedbackConfig(_ feedbackConfig: FeedbackConfig) {
    self.feedbackConfig = feedbackConfig
  }

  /// Registers a discrete-events-only subscriber (§6.4) — see
  /// `EventSubscriber.swift` for the partition rationale. Order is not
  /// meaningful; subscribers are notified after `audio.play(_:)` for the
  /// same event, in registration order.
  public func addEventSubscriber(_ subscriber: any EventSubscriber) {
    eventSubscribers.append(subscriber)
  }

  /// §7.5 manual silence: "silences all feedback immediately while leaving
  /// analysis running... MUST take effect within one audio buffer — cut the
  /// render, do not wait for the current utterance to finish." Forwards to
  /// both renderers immediately; does NOT touch `pendingState`/
  /// `confirmedState`/dwell timers/rate-limit bookkeeping — `ingest(_:at:)`
  /// keeps running the full state machine while silenced, it just stops
  /// short of calling `audio`/`speech` (see `fire(event:phrase:key:at:
  /// bypassRateLimit:)` in `FeedbackRouter+Announcements.swift`). That is
  /// what "analysis running" but zero renderer calls means in practice.
  public func setSilenced(_ silenced: Bool) async {
    isSilenced = silenced
    await audio.setSilenced(silenced)
    if silenced {
      await speech.stopSpeaking()
    }
  }

  /// Processes one frame of `EngineOutput`. See the type-level doc comment
  /// for the two-channel shape; `updateContinuousSonification` and the
  /// N-frame/dwell pipeline below are independent of each other and both
  /// run every call.
  public func ingest(_ output: EngineOutput, at time: ContinuousClock.Instant) async {
    recordForQuery(output)

    let discrete = Self.discreteState(for: output)

    if discrete == pendingState {
      pendingStreak += 1
    } else {
      pendingState = discrete
      pendingStreak = 1
    }

    if pendingStreak >= nFrameThreshold, confirmedState != discrete {
      let previous = confirmedState
      confirmedState = discrete
      confirmedStateStart = time
      // `output` threads through so §7.3's rung-3 recovery branch can
      // resolve "the problem, if there is one" without re-deriving it —
      // see `onConfirmedStateChanged`'s doc comment.
      await onConfirmedStateChanged(from: previous, to: discrete, output: output, at: time)
    }

    await tickAnnouncements(output: output, at: time)

    // Continuous channel runs LAST so a state transition's announcement and
    // its sonification consequence land on the same ingest — the atomic
    // arrival: enteredGoodZone fires above, and the beacon's cut (nil)
    // goes out here in the same call, not one frame later.
    await updateContinuousSonification(output, at: time)
  }

  var nFrameThreshold: Int {
    mode == .setup ? feedbackConfig.nFrameSetup : feedbackConfig.nFrameMonitor
  }

  /// §7.3 rung 1's delay, mode-selected (app field finding, 2026-08-02:
  /// "it takes ~1.5s for the no-face warning to sound after the tone
  /// stops"). Setup's active convergence loop cuts its positional tone the
  /// instant the face is lost (`updateContinuousSonification`'s
  /// resolve-then-send: `signalState != .ok` ⇒ `resolved = nil`), so 1.5s of
  /// unexplained silence before the earcon flirts with §6.1's silence
  /// ambiguity in a mode where the user is actively, attentively adjusting.
  /// Monitor's background posture keeps the original 1.5s — §7.3's own
  /// rationale ("covers turning to a second monitor, reaching for coffee,
  /// one bad frame") is specifically about NOT nagging an unattended call.
  /// See `FeedbackConfig.faceLostEarconDelaySetupMs`/
  /// `faceLostEarconDelayMonitorMs` for the two values this selects between.
  var faceLostEarconDelayMs: Int {
    mode == .setup
      ? feedbackConfig.faceLostEarconDelaySetupMs : feedbackConfig.faceLostEarconDelayMonitorMs
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter+Announcements.swift for the same
  // disagreement over multiline conditions).
  // swiftlint:disable opening_brace
  /// Milliseconds between two `ContinuousClock.Instant`s. `Duration`'s
  /// `.components` gives whole seconds plus attoseconds (1s = 1e18
  /// attoseconds, so 1ms = 1e15 attoseconds) — exact integer arithmetic,
  /// no floating-point drift across a long-running Monitor-mode session.
  static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant)
    -> Int
  {
    // swiftlint:enable opening_brace
    let (seconds, attoseconds) = (end - start).components
    return Int(seconds * 1000) + Int(attoseconds / 1_000_000_000_000_000)
  }
}
