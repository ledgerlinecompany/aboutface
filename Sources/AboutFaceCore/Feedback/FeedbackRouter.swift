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
/// becomes a `DiscreteState`, and `FeedbackRouter+Announcements.swift` for
/// how a confirmed `DiscreteState` becomes (or doesn't become) a call to
/// `audio`/`speech`.
public actor FeedbackRouter {
  let audio: any AudioRendering
  let speech: any SpeechRendering
  var eventSubscribers: [any EventSubscriber] = []

  var config: Config
  var feedbackConfig: FeedbackConfig
  var mode: FeedbackMode

  var isSilenced = false

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

  // MARK: - §7.3 face-lost ladder
  //
  // `faceLostRung`: 0 = nothing fired yet, 1 = the §7.3 "1.5s" earcon has
  // fired. Phase 4 adds 2 (≈5s spoken "No face.") and 3 (≈30s STOP +
  // `userLikelyAway`) — see `FeedbackRouter+Announcements.swift`'s
  // `tickAnnouncements(output:at:)` face-lost case for exactly where those
  // slot in.
  var faceLostRung = 0

  // MARK: - §5.2 Monitor-mode rate limiting
  var lastAnnouncementAt: ContinuousClock.Instant?
  var lastAnnouncementAtByCondition: [FeedbackCondition: ContinuousClock.Instant] = [:]

  public init(
    audio: any AudioRendering,
    speech: any SpeechRendering,
    config: Config = .defaults,
    feedbackConfig: FeedbackConfig = .defaults,
    mode: FeedbackMode = .setup
  ) {
    self.audio = audio
    self.speech = speech
    self.config = config
    self.feedbackConfig = feedbackConfig
    self.mode = mode
  }

  public func setMode(_ mode: FeedbackMode) {
    self.mode = mode
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
    await updateContinuousSonification(output, at: time)

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
      await onConfirmedStateChanged(from: previous, to: discrete, at: time)
    }

    await tickAnnouncements(output: output, at: time)
  }

  var nFrameThreshold: Int {
    mode == .setup ? feedbackConfig.nFrameSetup : feedbackConfig.nFrameMonitor
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter+Announcements.swift for the same
  // disagreement over multiline conditions).
  // swiftlint:disable opening_brace
  /// §6.2 continuous positional sonification. Per this round's brief:
  /// "continuous `SonificationTarget` updates while a face is tracked and
  /// out of dead zone... on entering good zone... stop positional updates."
  /// That "out of dead zone" clause is checked directly against
  /// `FramingState.inDeadZone` here — NOT gated by the announcement
  /// pipeline's N-frame/dwell machinery, so positional feedback stays
  /// real-time and resumes the instant `inDeadZone` flips back to `false`
  /// (§4's hysteresis already prevents that flip from chattering; adding a
  /// second debounce here would only add latency to a fast correction
  /// loop §1 exists to keep fast).
  ///
  /// Also requires `signalState == .ok`: `framing` can be non-`nil` even
  /// when `signalState` is `.noSignal` or `.lowConfidence` (a face was
  /// found on an otherwise near-uniform or low-confidence frame — see
  /// `makeOutput`'s test-support doc comment for the real
  /// `AnalysisEngine.process(_:)` code path that produces this), and §7.4
  /// ranks both of those ABOVE framing error in the priority ladder for
  /// exactly this reason: a positional reading taken during an unreliable
  /// signal is not trustworthy enough to sonify in real time, even though
  /// it exists. This is the continuous channel's own application of that
  /// same priority judgment — it has no ladder of its own to consult.
  func updateContinuousSonification(_ output: EngineOutput, at time: ContinuousClock.Instant) async
  {
    // swiftlint:enable opening_brace
    guard !isSilenced else { return }
    guard output.analysis.signalState == .ok else { return }
    guard let framing = output.framing, !framing.inDeadZone else { return }
    let target = SonificationTarget(
      errorX: framing.error.x,
      errorY: framing.error.y,
      distanceError: framing.distanceError,
      inDeadZone: framing.inDeadZone
    )
    await audio.update(target)
  }

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
