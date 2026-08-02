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
  public var nFrameSetup: Int
  public var nFrameMonitor: Int

  /// §7.3 face-lost escalation ladder, milliseconds elapsed since the
  /// (N-frame-confirmed) face-lost condition began. Phase 3 ships rung 0
  /// (nothing) and rung 1, the distinct earcon — MODE-SELECTED as of the
  /// app field finding below, rather than the single `faceLostEarconDelayMs`
  /// this used to be. `faceLostSpeechDelayMs` (rung 2, ~5s, spoken "No
  /// face.") and `faceLostStopDelayMs` (rung 3, ~30s, STOP +
  /// `userLikelyAway`) stay single-valued, unaffected by this split —
  /// reserved fields, present now so Phase 4 doesn't need another Config
  /// shape change, but `FeedbackRouter` does not read them yet. See
  /// `FeedbackRouter.tickAnnouncements(output:at:)`'s face-lost case for
  /// exactly where Phase 4 slots in.
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

  /// §6.1 "Holding good zone" liveness heartbeat interval, milliseconds.
  /// "The heartbeat is not optional" — users need to distinguish "good" from
  /// "the app crashed."
  public var heartbeatIntervalMs: Int

  /// §5.1/§5.2 per-mode rate limiting, and §16 (maintainer decision,
  /// 2026-08-01): "Monitor auto-enable will default ON... design your
  /// rate-limiting APIs so Monitor's limits... are Config-driven and
  /// mode-selectable." One `ModeLimits` value per `FeedbackMode` case.
  public var setup: ModeLimits
  public var monitor: ModeLimits

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
    heartbeatIntervalMs: Int,
    setup: ModeLimits,
    monitor: ModeLimits
  ) {
    self.nFrameSetup = nFrameSetup
    self.nFrameMonitor = nFrameMonitor
    self.faceLostEarconDelaySetupMs = faceLostEarconDelaySetupMs
    self.faceLostEarconDelayMonitorMs = faceLostEarconDelayMonitorMs
    self.faceLostSpeechDelayMs = faceLostSpeechDelayMs
    self.faceLostStopDelayMs = faceLostStopDelayMs
    self.heartbeatIntervalMs = heartbeatIntervalMs
    self.setup = setup
    self.monitor = monitor
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
    heartbeatIntervalMs: 7000,
    setup: ModeLimits(minAnnouncementIntervalMs: nil, minSameConditionIntervalMs: nil),
    monitor: ModeLimits(minAnnouncementIntervalMs: 20000, minSameConditionIntervalMs: 180_000)
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
