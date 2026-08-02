/// `Config.AudioGazeTrim` (§0/§11, tuning round 5). Split out of
/// `Config+Audio.swift` purely to stay under SwiftLint's `file_length` —
/// same reasoning `Config+AudioEarcons.swift` was split out for. This is
/// still a sibling of `Config.Audio` (nested directly under `Config`, not
/// inside `Audio` itself — see `Config+Audio.swift`'s own type-level doc
/// comment for why SwiftLint's `nesting` rule requires that shape here),
/// declared via `extension Config { ... }` exactly as if it lived inline.
extension Config {
  /// **Gaze trim (tuning round 5, maintainer-designed prototype).**
  /// Coarse-to-fine SEQUENTIAL feedback: the positional beacon
  /// (`Config.AudioPositional`) owns the continuous channel while the
  /// subject is out of the dead zone; once placed (dead zone, face ok),
  /// this MAY take over instead of pure silence-and-heartbeat (§6.1),
  /// giving a continuous fine-centering cue for head pose — clean/pure at
  /// the captured neutral baseline (`Config.TargetFraming
  /// .neutralYawDegrees`/`neutralPitchDegrees`), a gentle ingredient
  /// growing with deviation, beacon-polarity direction ("turn toward the
  /// sound," same philosophy as `AudioPositional.beaconPolarity`).
  /// `enabled` defaults `false` — this is an audition prototype
  /// (`aboutface-cli audition sweep --axis gaze-yaw`/`gaze-pitch`), not
  /// shipped behavior; the maintainer decides its fate by ear. See
  /// `FeedbackRouter+GazeTrim.swift` for activation gating and
  /// `RenderState+GazeTrim.swift` for synthesis.
  public struct AudioGazeTrim: Codable, Sendable, Equatable {
    /// Master enable (default `false`). Gates `FeedbackRouter` — see
    /// `FeedbackRouter.gazeTrimTarget(output:framing:)` — never the
    /// renderer itself, which (like every other `SonificationTarget`
    /// field) just renders whatever it's handed; this keeps the audition
    /// sweep (which talks to `AudioRenderer` directly, bypassing the
    /// router entirely — see `AuditionSupport.sweep`) working the same way
    /// every other sweep does, with no config mutation needed.
    public var enabled: Bool
    /// Overall gain for the trim tone, 0...1. Deliberately its OWN field
    /// (not derived from `AudioPositional.toneGain`) so it can be tuned
    /// independently — the §6.1-adjacent hard requirement is that trim
    /// read as markedly quieter than the beacon, and a shared gain knob
    /// would make that impossible to enforce by config alone. Default
    /// `0.05`, well below `AudioPositional.toneGain`'s `0.2`.
    public var gain: Double
    /// Exponential frequency mapping lower bound (Hz) for the trim
    /// register. Deliberately NON-OVERLAPPING with
    /// `AudioPositional.minToneHz`/`maxToneHz` (default 220-880 Hz, up to
    /// ~1244 Hz once `.speakers` `pitchSpeakerRangeExpansion` widens it) —
    /// see the type-level doc comment: trim must be different IN KIND from
    /// the beacon so a user never mistakes which loop they're in. Default
    /// `1400` — clearly above the beacon's register even in speakers mode
    /// (max ≈ 1244 Hz), preserving the different-in-kind guarantee.
    public var minHz: Double
    /// Exponential frequency mapping upper bound (Hz). Default `3200` —
    /// widened from the original 2400 after the first audition ("can't
    /// tell if anything other than pan is changing"): 1600–2400 was barely
    /// half an octave, too narrow to hear as pitch movement at trim gain;
    /// 1400–3200 is ≈1.2 octaves.
    public var maxHz: Double
    /// Yaw/pitch deviation magnitude (degrees) that maps to full
    /// pan-left/pan-right or the min/max trim frequency — the trim
    /// register's analog of `AudioPositional.errorRange`, but in degrees
    /// rather than normalized frame-fraction units. Values beyond this are
    /// clamped, not extrapolated. Default `20°`, matching the audition
    /// sweep's `-20°...+20°` range.
    public var deviationRangeDegrees: Double
    /// Per-axis dead-band (degrees): `FeedbackRouter` snaps a smoothed
    /// deviation to exactly `0` whenever `|deviation| < deadBandDegrees`,
    /// so raw Vision pose jitter (±2-3°, field-measured) can never keep
    /// the "neutral" reading flickering around zero — see
    /// `FeedbackRouter.gazeTrimTarget(output:framing:)`. Default `3°`,
    /// comfortably above the observed jitter band.
    public var deadBandDegrees: Double
    /// Exponential-moving-average window, in frames, applied to the raw
    /// yaw/pitch deviations before dead-banding — the trim-specific analog
    /// of `Config.smoothingWindow`, kept separate because trim only runs
    /// in Setup mode's 30Hz stream and may want its own time constant.
    /// Default `8`, matching `Config.smoothingWindow`'s own default.
    public var smoothingWindow: Int
    /// Milliseconds the trim tone's gain takes to ramp from `0` to full
    /// `gain` after activation — the "slow onset... no pop when entering
    /// the zone" requirement. See `RenderState.gazeTrimRampGain`. Default
    /// `300`.
    public var onsetRampMs: Double

    public init(
      enabled: Bool,
      gain: Double,
      minHz: Double,
      maxHz: Double,
      deviationRangeDegrees: Double,
      deadBandDegrees: Double,
      smoothingWindow: Int,
      onsetRampMs: Double
    ) {
      self.enabled = enabled
      self.gain = gain
      self.minHz = minHz
      self.maxHz = maxHz
      self.deviationRangeDegrees = deviationRangeDegrees
      self.deadBandDegrees = deadBandDegrees
      self.smoothingWindow = smoothingWindow
      self.onsetRampMs = onsetRampMs
    }
  }
}
