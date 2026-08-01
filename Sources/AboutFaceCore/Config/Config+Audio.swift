/// `AudioRenderer`'s Config surface (§6, §13 Phase 3). Split out of
/// `Config.swift` into this file (and `Config+AudioEarcons.swift`) purely to
/// stay under SwiftLint's `file_length`/`type_body_length` limits — these
/// are still all `Config`-nested types (`Config.Audio`, `Config.AudioEngine`,
/// etc.), declared via `extension Config { ... }`, exactly as if they lived
/// inline in `Config.swift`.
///
/// Every sub-type here is a **sibling** of `Audio` (nested directly under
/// `Config`, not inside `Audio` itself) rather than nested further —
/// SwiftLint's `nesting` rule (matching this project's existing
/// `Config.TargetFraming`/`Config.Lighting`/etc. convention) caps nesting
/// at one level below `Config`, so `Config.Audio.Positional` is not a legal
/// shape here the way it might be in an unconstrained design; it is
/// `Config.AudioPositional` instead.
///
/// All values below are documented starting points — per the maintainer's
/// 2026-08-01 §16 answer, sound design is simple synthesized primitives,
/// tuned by ear later against corpus replay, not fixed constants.
extension Config {
  /// Every number `AudioRenderer` needs. Grouped to mirror the renderer's
  /// own structure: engine format, scheme selection, the continuous
  /// positional/distance mapping, and the §6.1 discrete earcon set (in
  /// `Config+AudioEarcons.swift`).
  public struct Audio: Codable, Sendable, Equatable {
    public var engine: AudioEngine
    public var scheme: AudioScheme
    public var outputMode: AudioOutputMode
    public var positional: AudioPositional
    public var distance: AudioDistance
    public var heartbeat: AudioHeartbeat
    public var earcons: AudioEarcons

    public init(
      engine: AudioEngine,
      scheme: AudioScheme,
      outputMode: AudioOutputMode,
      positional: AudioPositional,
      distance: AudioDistance,
      heartbeat: AudioHeartbeat,
      earcons: AudioEarcons
    ) {
      self.engine = engine
      self.scheme = scheme
      self.outputMode = outputMode
      self.positional = positional
      self.distance = distance
      self.heartbeat = heartbeat
      self.earcons = earcons
    }

    /// Starting-point defaults (§16: "tuned by ear later against corpus
    /// replay"). `minToneHz`/`maxToneHz`/`referenceToneHz` default to A3
    /// (220 Hz) / A5 (880 Hz) / A4 (440 Hz) — two octaves spanning a
    /// geometric-mean-centered reference tone, chosen only for being a
    /// clean, easy-to-reason-about starting scale, not for any acoustic
    /// significance.
    public static let defaults = Audio(
      engine: AudioEngine(
        sampleRate: 48000,
        bufferFrameSize: 256
      ),
      scheme: AudioScheme(
        positional: .panPitch,
        schemeBEnabled: false,
        schemeBRefinementFraction: 0.2,
        schemeBMaxBeatHz: 8
      ),
      outputMode: .headphones,
      positional: AudioPositional(
        errorRange: 0.35,
        minToneHz: 220,
        maxToneHz: 880,
        referenceToneHz: 440,
        toneGain: 0.2,
        panSpeakerAttenuation: 0.5,
        pitchSpeakerRangeExpansion: 1.5,
        sequentialAxisThreshold: 0.15,
        beaconPolarity: true
      ),
      distance: AudioDistance(
        errorRange: 0.3,
        pulseRateMinHz: 1,
        pulseRateMaxHz: 8,
        pulseDepth: 0.6
      ),
      heartbeat: AudioHeartbeat(
        gain: 0.05,
        freqHz: 880,
        durationMs: 40
      ),
      earcons: .defaults
    )
  }

  /// `AVAudioEngine` render format (§3.1, §13 Phase 3 requirement 5).
  public struct AudioEngine: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var bufferFrameSize: Int

    public init(sampleRate: Double, bufferFrameSize: Int) {
      self.sampleRate = sampleRate
      self.bufferFrameSize = bufferFrameSize
    }
  }

  /// §6.2: three positional sonification schemes. Scheme A ("pan/pitch") and
  /// Scheme C ("sequential axis", mono fallback) are alternatives selected
  /// here; Scheme B ("zero-beat") is a refinement layer that composes *with*
  /// Scheme A only (§6.2: "Schemes A and B compose"), so it is a separate
  /// enable flag rather than a third case.
  public enum AudioPositionalScheme: String, Codable, Sendable, Equatable, CaseIterable {
    /// Scheme A (default, §6.2): stereo pan + pitch, simultaneous.
    case panPitch
    /// Scheme C (§6.2): horizontal to completion, then vertical. Mono
    /// fallback for output devices without usable stereo separation.
    case sequential
  }

  public struct AudioScheme: Codable, Sendable, Equatable {
    /// Default `.panPitch` (Scheme A, §6.2).
    public var positional: AudioPositionalScheme
    /// Scheme B (zero-beat nulling). §16 maintainer decision (2026-08-01):
    /// ships behind this flag, default OFF, until tuned against the corpus;
    /// the decision to flip the default is deferred.
    public var schemeBEnabled: Bool
    /// Scheme B is active only inside this fraction of `positional.errorRange`
    /// (§6.2: "final approach only — inside 20% of error range").
    public var schemeBRefinementFraction: Double
    /// Beat frequency (Hz) at the outer edge of the refinement zone
    /// (`schemeBRefinementFraction * positional.errorRange`); scales
    /// linearly to 0 Hz as error approaches zero, which is the whole point
    /// of a zero-beat null (§6.2).
    public var schemeBMaxBeatHz: Double

    public init(
      positional: AudioPositionalScheme,
      schemeBEnabled: Bool,
      schemeBRefinementFraction: Double,
      schemeBMaxBeatHz: Double
    ) {
      self.positional = positional
      self.schemeBEnabled = schemeBEnabled
      self.schemeBRefinementFraction = schemeBRefinementFraction
      self.schemeBMaxBeatHz = schemeBMaxBeatHz
    }
  }

  /// §6.2: "`Config` MUST have a headphones-vs-speakers setting — MacBook
  /// speakers at 50cm give poor imaging and this cannot be auto-detected
  /// reliably." Speakers mode narrows the pan range
  /// (`AudioPositional.panSpeakerAttenuation`) and widens the pitch range
  /// (`AudioPositional.pitchSpeakerRangeExpansion`) to compensate, per
  /// §6.2's own wording — poor stereo imaging on built-in speakers makes pan
  /// unreliable, so more of the positional information is pushed onto the
  /// axis (pitch) that speakers render faithfully regardless of imaging.
  public enum AudioOutputMode: String, Codable, Sendable, Equatable, CaseIterable {
    case headphones
    case speakers
  }

  /// §6.2 continuous positional mapping (Schemes A and C share these
  /// numbers; Scheme C applies them sequentially per axis instead of
  /// simultaneously).
  public struct AudioPositional: Codable, Sendable, Equatable {
    /// Error magnitude (same normalized units as `FramingState.error`, i.e.
    /// `SonificationTarget.errorX`/`errorY`) that maps to full
    /// pan-left/pan-right or the min/max tone frequency. Values beyond this
    /// are clamped, not extrapolated.
    public var errorRange: Double
    /// Exponential frequency mapping lower bound (Hz, §13 Phase 3
    /// requirement 2: "pitch ← errorY... exponential frequency mapping
    /// between Config min/max Hz").
    public var minToneHz: Double
    /// Exponential frequency mapping upper bound (Hz).
    public var maxToneHz: Double
    /// Center reference tone (Hz) — the frequency at zero error, and the
    /// fixed reference tone for Scheme B. Defaults to the geometric mean of
    /// `minToneHz`/`maxToneHz` so the exponential mapping is symmetric, but
    /// is independently tunable.
    public var referenceToneHz: Double
    /// Overall gain for the continuous positional tone(s), 0...1.
    public var toneGain: Double
    /// Multiplies the pan magnitude in `.speakers` `outputMode` (§6.2:
    /// "speakers mode narrows pan").
    public var panSpeakerAttenuation: Double
    /// Multiplies the (max - min) pitch span, recentered on
    /// `referenceToneHz`, in `.speakers` `outputMode` (§6.2: "...and widens
    /// pitch range to compensate").
    public var pitchSpeakerRangeExpansion: Double
    /// Scheme C only: fraction of `errorRange` within which the horizontal
    /// axis is considered "solved" and the sequential state machine
    /// advances to the vertical axis (§6.2: "Solve horizontal to
    /// completion, then vertical").
    public var sequentialAxisThreshold: Double
    /// **Beacon principle (2026-08-01 maintainer directive).** The sound is
    /// positioned at the TARGET, not at the subject's error — moving to
    /// "center" the sound also moves the subject into position. So pan and
    /// pitch encode the *negated* error (`-errorX`, `-errorY`), not the raw
    /// error: if the subject is right of target (`errorX > 0`), the
    /// corrective tone comes from their LEFT (pan negative) — they square
    /// off toward it. Same logic vertically: `errorY > 0` (subject above
    /// target) means the target is below them, so pitch goes LOW. `true`
    /// (default) is the shipped beacon polarity; `false` flips to the
    /// non-negated "error-marker" polarity (tone marks where the subject
    /// IS, not where the target is) for A/B tuning only — getting this
    /// flag's default wrong in shipped code is the audio equivalent of the
    /// §3.4 inverted-instruction failure mode, so it is exercised by
    /// dedicated polarity tests rather than left to the general direction
    /// tests to catch incidentally.
    public var beaconPolarity: Bool

    public init(
      errorRange: Double,
      minToneHz: Double,
      maxToneHz: Double,
      referenceToneHz: Double,
      toneGain: Double,
      panSpeakerAttenuation: Double,
      pitchSpeakerRangeExpansion: Double,
      sequentialAxisThreshold: Double,
      beaconPolarity: Bool
    ) {
      self.errorRange = errorRange
      self.minToneHz = minToneHz
      self.maxToneHz = maxToneHz
      self.referenceToneHz = referenceToneHz
      self.toneGain = toneGain
      self.panSpeakerAttenuation = panSpeakerAttenuation
      self.pitchSpeakerRangeExpansion = pitchSpeakerRangeExpansion
      self.sequentialAxisThreshold = sequentialAxisThreshold
      self.beaconPolarity = beaconPolarity
    }
  }

  /// §6.2: "Distance maps to pulse rate or filter brightness. Never
  /// volume." The pulse is an amplitude *gate* (tremolo), which is a
  /// temporal/rate parameter, not a loudness parameter — peak amplitude
  /// (`AudioPositional.toneGain`) is untouched by distance; only how fast
  /// the gate cycles changes. This is the resolution to the apparent
  /// tension with "never volume": that rule is about the *base* loudness
  /// being confounded with system output level and user attention, not
  /// about whether a rate-coded gate is allowed to exist at all.
  public struct AudioDistance: Codable, Sendable, Equatable {
    /// `|distanceError|` magnitude that maps to `pulseRateMaxHz`; beyond
    /// this the rate clamps rather than continuing to increase.
    public var errorRange: Double
    /// Gate rate (Hz) at zero distance error.
    public var pulseRateMinHz: Double
    /// Gate rate (Hz) at `errorRange` distance error.
    public var pulseRateMaxHz: Double
    /// Gate depth, 0...1: fraction of `AudioPositional.toneGain` the tone
    /// dips by at the bottom of each gate cycle. `0` = no gating; `1` =
    /// full on/off gate.
    public var pulseDepth: Double

    public init(
      errorRange: Double,
      pulseRateMinHz: Double,
      pulseRateMaxHz: Double,
      pulseDepth: Double
    ) {
      self.errorRange = errorRange
      self.pulseRateMinHz = pulseRateMinHz
      self.pulseRateMaxHz = pulseRateMaxHz
      self.pulseDepth = pulseDepth
    }
  }

  /// §6.1: "Holding good zone: silence + quiet liveness heartbeat every
  /// 7s." The *interval* is the router's concern (it decides WHEN to call
  /// `play(.livenessHeartbeat)`, per the shared contract); this is only
  /// what the tick sounds like once triggered.
  public struct AudioHeartbeat: Codable, Sendable, Equatable {
    /// Deliberately quiet (§13 Phase 3 requirement 5: "heartbeat gain") —
    /// present enough to confirm liveness, unobtrusive enough not to
    /// compete with the silence it's punctuating.
    public var gain: Double
    public var freqHz: Double
    public var durationMs: Double

    public init(gain: Double, freqHz: Double, durationMs: Double) {
      self.gain = gain
      self.freqHz = freqHz
      self.durationMs = durationMs
    }
  }
}
