/// Tunables for `FeedbackRouter` (§7) that are additive to the app's single
/// `Config` struct (§11: "One `Config` struct, versioned, `Codable`...
/// Every number in this document lives here") but do NOT live there this
/// round: `Config.swift` is owned by the concurrent audio-renderer agent for
/// this phase (see `docs/spec.md` §13 Phase 3), and this branch must not
/// touch it. `FeedbackRouter`'s own dwell time is deliberately NOT
/// duplicated here — it reads `Config.dwellMs` directly (already present,
/// already documented as "before it generates any announcement (§7.1)"),
/// since duplicating it here would violate §0/§11's "no numeric threshold is
/// hardcoded [twice]" spirit.
///
/// Both types are held on `Config` (`Config.feedback` / `Config.speech`) so
/// §11's "one Config struct, versioned, Codable" holds; they are defined in
/// this file, beside the router that consumes them. No `Config.version`
/// bump was needed: `ConfigStore`'s lenient decode fills newly added keys
/// from defaults per-key, and the version field is reserved for genuinely
/// breaking migrations.
public struct FeedbackConfig: Codable, Sendable, Equatable {
  /// §7.2 "general N-frame requirement" — how many CONSECUTIVE frames a new
  /// discrete condition must be observed for before `FeedbackRouter` treats
  /// it as a real candidate (as opposed to a blink, a hand raised to the
  /// face, a sip of coffee). Two values because the two shipped modes (§5)
  /// analyze at different rates — Setup at 30Hz, Monitor at 5Hz — and the
  /// spec gives per-rate starting points ("default 5 at 30Hz, 3 at 5Hz").
  /// `FeedbackRouter` selects between them via its `FeedbackMode`, not a raw
  /// Hz value, since mode IS the rate hint in this codebase (§5.1/§5.2 each
  /// name their own fixed analysis rate).
  ///
  /// `nFrameMonitor`'s default of 3 has been sitting here since before
  /// Monitor mode's capture/analysis pipeline existed, on the assumption
  /// that Monitor would eventually actually analyze at 5Hz. The mode
  /// plumbing PR (§13 Phase 4, `Config.Camera.monitor.analysisHz`,
  /// `AnalysisRateDecimator`) is what makes that assumption true for the
  /// first time — before it, Monitor mode simply didn't exist as a distinct
  /// capture/analysis configuration, so this value was untested against its
  /// own stated rationale.
  public var nFrameSetup: Int
  public var nFrameMonitor: Int

  /// §7.3 face-lost escalation ladder, milliseconds elapsed since the
  /// (N-frame-confirmed) face-lost condition began. Rung 1, the distinct
  /// earcon, is MODE-SELECTED as of the app field finding below, rather
  /// than the single `faceLostEarconDelayMs` this used to be.
  /// `faceLostSpeechDelayMs` (rung 2, ~5s, spoken "No face.") and
  /// `faceLostStopDelayMs` (rung 3, ~30s, STOP + `userLikelyAway`) stay
  /// single-valued, unaffected by this split — the escalation posture
  /// §7.3 asks for doesn't vary by mode the way rung 1's timing does (§5.2
  /// already carves Monitor's speech OUT of its earcons-only default
  /// specifically for this ladder, so there is no per-mode "should this
  /// speak at all" left to key a second field on). See
  /// `FeedbackRouter.tickFaceLostLadder(from:at:)` in
  /// `FeedbackRouter+FaceLost.swift` for exactly how each field gates its
  /// rung.
  ///
  /// **Split into per-mode fields (app field finding, 2026-08-02): "it
  /// takes ~1.5s for the no-face warning to sound after the tone stops."**
  /// 1500ms rung-1 delay is right for Monitor — §7.3's own rationale
  /// ("covers turning to a second monitor, reaching for coffee, one bad
  /// frame") is explicitly about a background call the user isn't staring
  /// at. Setup is the opposite posture: an active convergence loop where
  /// the positional tone now cuts INSTANTLY on face loss
  /// (`FeedbackRouter.updateContinuousSonification`'s resolve-then-send:
  /// `signalState != .ok` ⇒ send `nil`), so 1500ms of unexplained silence
  /// before the earcon flirts with §6.1's silence ambiguity in the one mode
  /// where the user is watching closely. `FeedbackRouter.mode` picks
  /// between these two fields via `FeedbackRouter.faceLostEarconDelayMs`
  /// (that computed property's own doc comment has the router-side half of
  /// this story) — this follows the SAME per-mode-fields shape as
  /// `ModeLimits` below, rather than inventing a parallel pattern, per
  /// §0/§11's "no numeric threshold is hardcoded" spirit (one canonical
  /// place per tunable, keyed by the thing that actually varies it).
  public var faceLostEarconDelaySetupMs: Int
  public var faceLostEarconDelayMonitorMs: Int
  public var faceLostSpeechDelayMs: Int
  public var faceLostStopDelayMs: Int

  /// Maintainer decision, 2026-08-03: "speak and earcon by default, but
  /// turning off the speech is a choice on both sides" — "both sides"
  /// meaning the departure (rung 2's "No face.") and the return (rung 3's
  /// recovery phrase) are each INDEPENDENTLY switchable off, and neither
  /// switch touches the earcon it accompanies. Both default `true` (§0/§11:
  /// a user-facing tunable, not a compile-time constant, like every other
  /// field here) because §7.3's escalation is safety-relevant — opting out
  /// of being told "the app thinks you're gone" should be a deliberate act,
  /// not an accident of a default nobody looked at.
  ///
  /// Gates rung 2's spoken "No face." (`Lexicon.Instruction.noFace`) only.
  /// `false` still fires rung 1's earcon on schedule and still advances the
  /// ladder to rung 2 and then rung 3 (STOP) at their normal delays — see
  /// `FeedbackRouter.tickFaceLostLadder(from:at:)`'s own doc comment for
  /// why disabling the phrase must never disable the rung transition or
  /// rung 3's reachability. With this `false`, rung 2 becomes silent in
  /// both channels it could have used (no event, no phrase), so `fire`'s
  /// own no-op short-circuit means it produces zero renderer calls while
  /// still updating `faceLostRung`.
  public var faceLostSpeechEnabled: Bool
  /// Gates the spoken recovery phrase on reacquisition from a rung-3 away
  /// episode — "Back, centered." or the live problem's instruction, per
  /// `FeedbackRouter.handleFaceLostReacquisition(from:to:output:at:)`.
  /// `false` still fires the `.faceReacquired` earcon and still clears
  /// `userLikelyAway` unconditionally; the toggle governs speech only, never
  /// the exit from silence. (Rung 1/2-only recoveries already speak nothing
  /// regardless of this flag — see that method's own doc comment — so this
  /// only ever has an audible effect on episodes that reached rung 3.)
  public var faceLostRecoverySpeechEnabled: Bool

  /// §6.1 "Holding good zone" liveness heartbeat interval, milliseconds.
  /// "The heartbeat is not optional" — users need to distinguish "good" from
  /// "the app crashed."
  public var heartbeatIntervalMs: Int
  /// Extra delay between good-zone CONFIRMATION (N-frame filtered) and the
  /// entry earcon. Default 0 — atomic-arrival fix (field finding: "the
  /// chime is about half a second after the sound cuts out… disorienting"):
  /// the beacon now plays through the confirmation window and the cut and
  /// chime fire together at confirmation. §7.1's 800ms dwell is
  /// deliberately NOT applied to this one transition — its anti-chatter
  /// job is already done here by N-frame confirmation plus §4 hysteresis,
  /// and §6.1's no-ambiguous-silence requirement outranks uniform dwell.
  public var goodZoneChimeDelayMs: Int

  /// Phase 4.5 (design doc §3.3): how close the face's bounding box may come
  /// to a frame edge before it counts as CROPPED, normalized to the frame.
  /// See `FrameEdgeCrop` for why proximity rather than size is the test.
  /// `0` means "only when it actually reaches the boundary."
  public var frameEdgeCropMargin: Double

  /// Whether headroom cropping — the top of the head trimmed — counts.
  /// Default `false`: it is common in ordinary laptop use, mostly benign, and
  /// counting it would put many users permanently in the warned state, which
  /// costs the ambient pulse's one bit its meaning. See `FrameEdgeCrop`.
  public var frameEdgeCropFlagsTopEdge: Bool

  /// How long the face must stay cropped before the status pulse changes
  /// character, milliseconds. Deliberately LONG — design doc §3.3.1: "this is
  /// 'you have been like this for a while,' not 'you moved.'"
  public var outOfFrameEnterMs: Int

  /// How long it must stay uncropped before the pulse returns to normal.
  /// Shorter than `outOfFrameEnterMs` on purpose, which is §4's
  /// hysteresis rule oriented the way it should be for a WARNING state: slow
  /// to alarm, prompt to reassure. A user who has just corrected their
  /// position should hear that it worked without waiting out the full entry
  /// dwell again.
  public var outOfFrameExitMs: Int

  /// §12.5: whether the good-zone ARRIVAL EARCON still sounds while Center
  /// Stage is active. Default `true` — the chime plays.
  ///
  /// This started life suppressed, on the argument that the chime marks the
  /// end of a correction the user made, and under Center Stage they made
  /// none. The maintainer never got to judge that by ear, because the
  /// face-lost ladder was cycling over the top of it (see
  /// `FeedbackRouter.faceLostEpisodeWasAudible`); once that was fixed his
  /// call was "worth trying turned on, perhaps behind a toggle," which is
  /// what this is. Flipping it needs no rebuild — `PipelineModel
  /// .pushConfigToFeedbackChain` forwards `Config.feedback` to the live
  /// router, so the Debug panel's toggle takes effect mid-session, which is
  /// the only way a question like this gets answered honestly.
  ///
  /// **Scope: the earcon only.** Setup's spoken `Instruction.centered`
  /// ("Centered.") stays suppressed under Center Stage no matter how this is
  /// set, and deliberately so — a spoken "Centered." is a framing VERDICT,
  /// which is exactly what §12.5 forbids while the OS owns the crop ("silently
  /// reporting a framing problem the OS is already correcting is worse than
  /// reporting nothing," and asserting the good case is the same claim with
  /// the sign flipped). The chime is not a verdict; it is a punctuation mark
  /// saying "you are placed now," and whether that is useful when the
  /// placement was automatic is a genuine open question about how it SOUNDS,
  /// not about what is true.
  public var centerStageArrivalChimeEnabled: Bool

  /// §5.1/§5.2 per-mode rate limiting, and §16 (maintainer decision,
  /// 2026-08-01): "Monitor auto-enable will default ON... design your
  /// rate-limiting APIs so Monitor's limits... are Config-driven and
  /// mode-selectable." One `ModeLimits` value per `FeedbackMode` case.
  public var setup: ModeLimits
  public var monitor: ModeLimits

  /// §5.3 Query mode tunables. See `Query`'s own doc comment.
  public var query: Query

  /// §5.3: "One-shot burst of analysis (~10 frames, ~300ms), then a single
  /// terse spoken summary" and "'problems only' variant that omits fields
  /// that are fine." See `FeedbackRouter+Query.swift`'s type-level doc
  /// comment for exactly what "burst" means in this codebase (a ring of the
  /// most recently `ingest`ed frames, not a freshly-triggered capture) and
  /// why `burstFrameCount` — not a millisecond duration — is the
  /// Config-keyed knob: `FeedbackRouter` has no notion of capture cadence of
  /// its own, only a count of frames already handed to it.
  public struct Query: Codable, Sendable, Equatable {
    /// §5.3 "~10 frames" — how many of the most recently ingested
    /// `EngineOutput`s `FeedbackRouter.performQuery(at:)` aggregates over.
    public var burstFrameCount: Int
    /// §5.3 "problems only" variant: omit fields (or, for the merged
    /// gaze/tilt field, whichever half of it) that are fine.
    public var problemsOnly: Bool

    public init(burstFrameCount: Int, problemsOnly: Bool) {
      self.burstFrameCount = burstFrameCount
      self.problemsOnly = problemsOnly
    }

    public static let defaults = Query(burstFrameCount: 10, problemsOnly: false)
  }

  /// A mode's rate-limit ceiling on discrete announcements (§5.1: "no rate
  /// limiting beyond the dwell time" for Setup — both fields `nil`; §5.2:
  /// "max 1 announcement per 20s. Same condition not repeated within 3
  /// minutes" for Monitor's shipped defaults). Does NOT gate the continuous
  /// positional sonification loop, the §6.1 liveness heartbeat, or the
  /// §7.3 face-lost ladder / recovery announcement — those are exempted by
  /// design (see `FeedbackRouter.fire(event:phrase:key:at:bypassRateLimit:)`).
  public struct ModeLimits: Codable, Sendable, Equatable {
    /// Minimum milliseconds between ANY two announcements, regardless of
    /// condition. `nil` = no limit.
    public var minAnnouncementIntervalMs: Int?
    /// Minimum milliseconds before the SAME condition may announce again.
    /// `nil` = no limit.
    public var minSameConditionIntervalMs: Int?

    public init(minAnnouncementIntervalMs: Int?, minSameConditionIntervalMs: Int?) {
      self.minAnnouncementIntervalMs = minAnnouncementIntervalMs
      self.minSameConditionIntervalMs = minSameConditionIntervalMs
    }
  }

  public init(
    nFrameSetup: Int,
    nFrameMonitor: Int,
    faceLostEarconDelaySetupMs: Int,
    faceLostEarconDelayMonitorMs: Int,
    faceLostSpeechDelayMs: Int,
    faceLostStopDelayMs: Int,
    faceLostSpeechEnabled: Bool = true,
    faceLostRecoverySpeechEnabled: Bool = true,
    heartbeatIntervalMs: Int,
    goodZoneChimeDelayMs: Int = 0,
    frameEdgeCropMargin: Double = 0.01,
    frameEdgeCropFlagsTopEdge: Bool = false,
    outOfFrameEnterMs: Int = 10000,
    outOfFrameExitMs: Int = 3000,
    centerStageArrivalChimeEnabled: Bool = true,
    setup: ModeLimits,
    monitor: ModeLimits,
    query: Query = .defaults
  ) {
    self.nFrameSetup = nFrameSetup
    self.nFrameMonitor = nFrameMonitor
    self.faceLostEarconDelaySetupMs = faceLostEarconDelaySetupMs
    self.faceLostEarconDelayMonitorMs = faceLostEarconDelayMonitorMs
    self.faceLostSpeechDelayMs = faceLostSpeechDelayMs
    self.faceLostStopDelayMs = faceLostStopDelayMs
    self.faceLostSpeechEnabled = faceLostSpeechEnabled
    self.faceLostRecoverySpeechEnabled = faceLostRecoverySpeechEnabled
    self.heartbeatIntervalMs = heartbeatIntervalMs
    self.goodZoneChimeDelayMs = goodZoneChimeDelayMs
    self.frameEdgeCropMargin = frameEdgeCropMargin
    self.frameEdgeCropFlagsTopEdge = frameEdgeCropFlagsTopEdge
    self.outOfFrameEnterMs = outOfFrameEnterMs
    self.outOfFrameExitMs = outOfFrameExitMs
    self.centerStageArrivalChimeEnabled = centerStageArrivalChimeEnabled
    self.setup = setup
    self.monitor = monitor
    self.query = query
  }

  /// §7.2/§7.3/§6.1/§5.2 starting-point defaults — tune against the test
  /// corpus (§14) once real clips exist, same as every other `Config`
  /// default in this codebase. `faceLostEarconDelaySetupMs` (500) and
  /// `faceLostEarconDelayMonitorMs` (1500) per the app field finding on
  /// `faceLostEarconDelaySetupMs`'s own doc comment above.
  public static let defaults = FeedbackConfig(
    nFrameSetup: 5,
    nFrameMonitor: 3,
    faceLostEarconDelaySetupMs: 500,
    faceLostEarconDelayMonitorMs: 1500,
    faceLostSpeechDelayMs: 5000,
    faceLostStopDelayMs: 30000,
    faceLostSpeechEnabled: true,
    faceLostRecoverySpeechEnabled: true,
    heartbeatIntervalMs: 7000,
    goodZoneChimeDelayMs: 0,
    frameEdgeCropMargin: 0.01,
    frameEdgeCropFlagsTopEdge: false,
    outOfFrameEnterMs: 10000,
    outOfFrameExitMs: 3000,
    centerStageArrivalChimeEnabled: true,
    setup: ModeLimits(minAnnouncementIntervalMs: nil, minSameConditionIntervalMs: nil),
    monitor: ModeLimits(minAnnouncementIntervalMs: 20000, minSameConditionIntervalMs: 180_000),
    query: .defaults
  )
}

/// Tunables for `SpeechRenderer` (§6.3). Held on `Config.speech`
/// (§11: one Config struct); defined here beside the router that consumes
/// its sibling `FeedbackConfig`.
public struct SpeechConfig: Codable, Sendable, Equatable {
  /// §6.3: "Default rate well above `AVSpeechUtteranceDefaultSpeechRate`...
  /// Default 0.62, exposed as a slider." Deliberately far above Apple's
  /// default (`AVSpeechUtteranceDefaultSpeechRate` is ~0.5 and reads as
  /// unusably slow for this audience per the spec's own framing) — this is
  /// a considered starting point, not an oversight, so do not "fix" it back
  /// toward the system default.
  public var rate: Float
  public var volume: Float
  public var pitchMultiplier: Float

  /// `AVSpeechSynthesisVoice.identifier`, or `nil` to defer to
  /// `SpeechRenderer`'s own default-selection heuristic (§6.3: "Default to a
  /// voice timbrally distinct from common VoiceOver defaults... Do not
  /// accept whatever `speechVoices()` returns first"). The Phase 5
  /// voice-picker UI writes a concrete identifier here once the user picks
  /// one explicitly.
  public var voiceIdentifier: String?

  public init(rate: Float, volume: Float, pitchMultiplier: Float, voiceIdentifier: String?) {
    self.rate = rate
    self.volume = volume
    self.pitchMultiplier = pitchMultiplier
    self.voiceIdentifier = voiceIdentifier
  }

  public static let defaults = SpeechConfig(
    rate: 0.62,
    volume: 1.0,
    pitchMultiplier: 1.0,
    voiceIdentifier: nil
  )
}
