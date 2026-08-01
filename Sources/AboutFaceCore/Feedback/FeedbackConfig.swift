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
/// **Follow-up for the integrator, after both `phase3/feedback-router` and
/// `phase3/audio-renderer` merge:** fold `FeedbackConfig` and `SpeechConfig`
/// in as new fields on `Config` (e.g. `Config.feedback: FeedbackConfig`,
/// `Config.speech: SpeechConfig`), bump `Config.version`, and delete this
/// file's `static let defaults` split in favor of `Config.defaults`
/// composing them. That is a small, mechanical follow-up, not a redesign —
/// every field here is already `Codable`/`Sendable`/`Equatable` and shaped
/// like every other `Config` sub-struct.
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
  /// (nothing) and rung 1 (`faceLostEarconDelayMs`, the distinct earcon).
  /// `faceLostSpeechDelayMs` (rung 2, ~5s, spoken "No face.") and
  /// `faceLostStopDelayMs` (rung 3, ~30s, STOP + `userLikelyAway`) are
  /// reserved fields — present now so Phase 4 doesn't need another Config
  /// shape change, but `FeedbackRouter` does not read them yet. See
  /// `FeedbackRouter.tickAnnouncements(output:at:)`'s face-lost case for
  /// exactly where Phase 4 slots in.
  public var faceLostEarconDelayMs: Int
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
    faceLostEarconDelayMs: Int,
    faceLostSpeechDelayMs: Int,
    faceLostStopDelayMs: Int,
    heartbeatIntervalMs: Int,
    setup: ModeLimits,
    monitor: ModeLimits
  ) {
    self.nFrameSetup = nFrameSetup
    self.nFrameMonitor = nFrameMonitor
    self.faceLostEarconDelayMs = faceLostEarconDelayMs
    self.faceLostSpeechDelayMs = faceLostSpeechDelayMs
    self.faceLostStopDelayMs = faceLostStopDelayMs
    self.heartbeatIntervalMs = heartbeatIntervalMs
    self.setup = setup
    self.monitor = monitor
  }

  /// §7.2/§7.3/§6.1/§5.2 starting-point defaults — tune against the test
  /// corpus (§14) once real clips exist, same as every other `Config`
  /// default in this codebase.
  public static let defaults = FeedbackConfig(
    nFrameSetup: 5,
    nFrameMonitor: 3,
    faceLostEarconDelayMs: 1500,
    faceLostSpeechDelayMs: 5000,
    faceLostStopDelayMs: 30000,
    heartbeatIntervalMs: 7000,
    setup: ModeLimits(minAnnouncementIntervalMs: nil, minSameConditionIntervalMs: nil),
    monitor: ModeLimits(minAnnouncementIntervalMs: 20000, minSameConditionIntervalMs: 180_000)
  )
}

/// Tunables for `SpeechRenderer` (§6.3). Additive/out-of-`Config` for the
/// same reason as `FeedbackConfig` above — see that type's doc comment for
/// the fold-in follow-up.
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
