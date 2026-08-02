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
    /// Tuning round 5 (maintainer-designed audition prototype, §6.1/§6.2-
    /// adjacent): the gaze-trim continuous cue. See `AudioGazeTrim`'s own
    /// doc comment.
    public var gazeTrim: AudioGazeTrim

    public init(
      engine: AudioEngine,
      scheme: AudioScheme,
      outputMode: AudioOutputMode,
      positional: AudioPositional,
      distance: AudioDistance,
      heartbeat: AudioHeartbeat,
      earcons: AudioEarcons,
      gazeTrim: AudioGazeTrim
    ) {
      self.engine = engine
      self.scheme = scheme
      self.outputMode = outputMode
      self.positional = positional
      self.distance = distance
      self.heartbeat = heartbeat
      self.earcons = earcons
      self.gazeTrim = gazeTrim
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
        beaconPolarity: true,
        verticalTimbreEnabled: true,
        maxBrightnessMix: 0.5,
        maxDarknessMix: 0.5,
        brightnessStyle: .saw,
        overdriveMaxDrive: 6
      ),
      distance: AudioDistance(
        errorRange: 0.3,
        pulseRateMinHz: 1,
        pulseRateMaxHz: 8,
        pulseDepth: 0.6,
        directionalPulseEnabled: true,
        closePulseSharpness: 3.5
      ),
      heartbeat: AudioHeartbeat(
        gain: 0.05,
        freqHz: 880,
        durationMs: 40
      ),
      earcons: .defaults,
      gazeTrim: AudioGazeTrim(
        enabled: false,
        gain: 0.05,
        minHz: 1600,
        maxHz: 2400,
        deviationRangeDegrees: 20,
        deadBandDegrees: 3,
        smoothingWindow: 8,
        onsetRampMs: 300
      )
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

  /// The "target above" brightness ingredient's synthesis CHARACTER
  /// (2026-08-02 round-2 audition feedback): "The below indicator [the
  /// sub-octave darkness ingredient] is clear, the above indicator is a
  /// little less clear. I think maybe something a little more overdriven?
  /// Or mix in a saw or something?" — round 1's additive 2nd/3rd-harmonic
  /// blend was judged too subtle. Rather than guess which replacement reads
  /// better, all three are shipped and selectable (§0/§16: sound design is
  /// tuned by ear against the corpus, not decided up front) so the
  /// maintainer can audition and pick — see `AuditionSweep`'s `--brightness`
  /// override for the exact A/B workflow this exists for. Every style obeys
  /// the same purity-at-center invariant: at zero vertical error the
  /// ingredient's contribution is exactly zero, not merely small — see
  /// `RenderState.brightnessComponent`.
  public enum BrightnessStyle: String, Codable, Sendable, Equatable, CaseIterable {
    /// Round 1's baseline: additive blend of the 2nd and 3rd harmonic of
    /// the vertical carrier. Kept verbatim (not retuned) so it stays an
    /// honest comparison point against the two round-2 alternatives below.
    case harmonics
    /// Round-2 default (the maintainer's stated lean): waveshapes the
    /// carrier itself with a gain-normalized `tanh` drive that grows with
    /// brightness intensity, crossfaded in from a clean identity pass at
    /// zero intensity. See `RenderState.overdriveComponent` and
    /// `AudioPositional.overdriveMaxDrive`.
    case overdrive
    /// Crossfades the carrier toward a band-limited (polyBLEP) sawtooth at
    /// the same frequency/phase. See `RenderState.polyBlepSaw`.
    case saw
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
    /// **Vertical-axis timbre differentiation (2026-08-02 maintainer tuning
    /// directive, first audition session).** "It's obvious when sounds are
    /// off-center, but I'm not sure if it's obvious what pitch we're aiming
    /// to center on vertically" — stereo center is self-evident, a target
    /// PITCH is not (it relies on memory). When enabled, the vertical tone
    /// (Scheme A's pitch tone; Scheme C's tone while resolving the vertical
    /// axis) stays a pure sine at zero vertical error and blends in a
    /// distinct timbral ingredient — growing with `|errorY|` — on each side,
    /// so purity itself (pre-attentively detectable, like Scheme B's
    /// zero-beat null) marks the target rather than a remembered pitch. See
    /// `maxBrightnessMix`/`maxDarknessMix` and
    /// `RenderState.verticalTimbreMix` for the synthesis, and
    /// `AudioRendererVerticalTimbreTests` for the hand-derived acceptance
    /// cases. Default `true`.
    public var verticalTimbreEnabled: Bool
    /// Ingredient added when the TARGET is ABOVE the subject (beacon pitch
    /// goes high): brightness, i.e. added upper harmonics (2nd/3rd) of the
    /// pitch tone. Gain of the harmonic blend at the outer edge of
    /// `errorRange`, 0...1; scales linearly (down to 0) as the post-polarity
    /// pitch value approaches 0. Metaphor-congruent with "brighter/higher."
    public var maxBrightnessMix: Double
    /// Ingredient added when the TARGET is BELOW the subject (beacon pitch
    /// goes low): darkness, i.e. an added sub-octave (`f/2`) component.
    /// Gain of the sub-octave blend at the outer edge of `errorRange`,
    /// 0...1; scales linearly (down to 0) as the post-polarity pitch value
    /// approaches 0. Metaphor-congruent with "darker/lower."
    public var maxDarknessMix: Double
    /// Which synthesis character the brightness ingredient above uses.
    /// Default `.saw` — chosen BY EAR in the 2026-08-02 round-3 A/B
    /// (`audition sweep --axis y --brightness <style>`): "Saw is by far
    /// the clearest; I couldn't even notice the difference in brightness
    /// overdrive." Acoustically consistent: tanh's odd harmonics roll off
    /// steeply and are near-inaudible on a few-hundred-Hz carrier through
    /// built-in speakers, while polyBLEP saw carries the full harmonic
    /// series. `.overdrive`/`.harmonics` remain selectable for
    /// re-audition on other output hardware.
    public var brightnessStyle: BrightnessStyle
    /// `.overdrive` style only: the `tanh` drive coefficient at full
    /// brightness intensity (`brightnessMix == maxBrightnessMix`); drive
    /// ramps from `1` at zero intensity up to this value. Capped (default
    /// `6`) rather than left unbounded — `tanh`'s odd-harmonic content
    /// rolls off fast, but it is not literally band-limited, and this
    /// renderer's vertical tone lives in a few-hundred-Hz range against a
    /// 48kHz sample rate, so even the harshest harmonics this cap produces
    /// sit comfortably below Nyquist (see `RenderState.overdriveComponent`
    /// for the full aliasing-tradeoff reasoning).
    public var overdriveMaxDrive: Double

    public init(
      errorRange: Double,
      minToneHz: Double,
      maxToneHz: Double,
      referenceToneHz: Double,
      toneGain: Double,
      panSpeakerAttenuation: Double,
      pitchSpeakerRangeExpansion: Double,
      sequentialAxisThreshold: Double,
      beaconPolarity: Bool,
      verticalTimbreEnabled: Bool,
      maxBrightnessMix: Double,
      maxDarknessMix: Double,
      brightnessStyle: BrightnessStyle,
      overdriveMaxDrive: Double
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
      self.verticalTimbreEnabled = verticalTimbreEnabled
      self.maxBrightnessMix = maxBrightnessMix
      self.maxDarknessMix = maxDarknessMix
      self.brightnessStyle = brightnessStyle
      self.overdriveMaxDrive = overdriveMaxDrive
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
