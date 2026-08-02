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
        schemeBMaxBeatHz: 8,
        schemeBClickGain: 0.18,
        schemeBClickDurationMs: 6
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
        timbreOnsetExponent: 2.0,
        overdriveMaxDrive: 6,
        errorQuantizationStep: 0.03,
        quantizationGlideMs: 30
      ),
      distance: AudioDistance(
        errorRange: 0.3,
        pulseRateMinHz: 1,
        pulseRateMaxHz: 8,
        closePulseDepth: 0.95,
        farPulseDepth: 0.4,
        audibleRampMultiplier: 2,
        audibleRampStartError: 0.02,
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
        minHz: 1400,
        maxHz: 3200,
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
  /// here; Scheme B (originally "zero-beat", now a percussive click train —
  /// see `AudioScheme.schemeBMaxBeatHz`'s doc comment for the 2026-08-02
  /// redesign) is a refinement layer that composes *with* Scheme A only
  /// (§6.2: "Schemes A and B compose"), so it is a separate enable flag
  /// rather than a third case.
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
    /// Scheme B (§16 maintainer decision, 2026-08-01: ships behind this
    /// flag, default OFF, until tuned against the corpus; the decision to
    /// flip the default is deferred). See `schemeBMaxBeatHz`'s doc comment
    /// for what Scheme B actually sounds like as of the 2026-08-02
    /// percussive redesign.
    public var schemeBEnabled: Bool
    /// Scheme B is active only inside this fraction of `positional.errorRange`
    /// (§6.2: "final approach only — inside 20% of error range"). Unchanged
    /// by the 2026-08-02 percussive redesign — still the refinement-zone
    /// gate, just gating a click train now instead of a beat tone.
    public var schemeBRefinementFraction: Double
    /// **Percussive redesign (2026-08-02 convergence-experiment action
    /// round, item 3).** Round 1's Scheme B trial (`p1-scheme-b`,
    /// `docs/tuning/2026-08-02-convergence-experiment.md`) shipped the
    /// original design this field's name still describes — a fixed
    /// reference tone plus a moving tone whose BEAT frequency tracked
    /// error, nulling to 0 Hz at zero error — and it came back unjudgeable:
    /// "I wasn't sure if I was supposed to get it to match the other one."
    /// The two-tone beat sat in the same register as Scheme A's own tonal
    /// beacon, so the maintainer (blind to which profile was which)
    /// couldn't reliably tell the refinement layer apart from the thing it
    /// was refining. Maintainer's redesign brief: "something more
    /// percussive/clicky, since we don't use that yet."
    ///
    /// Scheme B is now a CLICK TRAIN, not a tone: `RenderState
    /// .schemeBSample` (`RenderState+SchemeB.swift`) fires a short,
    /// non-tonal noise transient (`schemeBClickDurationMs`) at a repetition
    /// rate equal to what this field's beat frequency would have been —
    /// this field keeps its name and its mapping (linear over the
    /// refinement zone, reaching this value at the outer edge and 0 —  i.e.
    /// no clicks at all, true silence — at zero error) unchanged; only what
    /// happens AT that rate changed. The clicks are non-tonal by
    /// construction (filtered noise, no carrier pitch), so — unlike the old
    /// beat tone — they can never be mistaken for Scheme A's beacon: two
    /// orthogonal "you're there" channels once paired with the quantized
    /// beacon's tonal-purity snap (`AudioPositional.errorQuantizationStep`,
    /// default `0.03` as of this same action round) — timbre says "pure,"
    /// rhythm says "silent," and both now mean the same thing at once. See
    /// `Fixtures/tuning-profiles/README.md`'s `p6`/`p7` for the re-trial
    /// this composition motivates.
    public var schemeBMaxBeatHz: Double
    /// Scheme B click train's own gain (2026-08-02 percussive redesign) —
    /// deliberately a separate field from `AudioPositional.toneGain`: the
    /// click train is a distinct signal path (noise transient, not a tonal
    /// carrier) composited on top of Scheme A, not a variation on the
    /// beacon's own volume.
    public var schemeBClickGain: Double
    /// Scheme B click transient duration in milliseconds (2026-08-02
    /// percussive redesign) — deliberately "a few ms," much shorter than
    /// `Config.AudioEarcons.FaceLost`'s noise burst (default 300ms): the
    /// click must read as a percussive tick, not a burst. See
    /// `RenderState.schemeBSample`'s doc comment.
    public var schemeBClickDurationMs: Double

    public init(
      positional: AudioPositionalScheme,
      schemeBEnabled: Bool,
      schemeBRefinementFraction: Double,
      schemeBMaxBeatHz: Double,
      schemeBClickGain: Double = 0.18,
      schemeBClickDurationMs: Double = 6
    ) {
      self.positional = positional
      self.schemeBEnabled = schemeBEnabled
      self.schemeBRefinementFraction = schemeBRefinementFraction
      self.schemeBMaxBeatHz = schemeBMaxBeatHz
      self.schemeBClickGain = schemeBClickGain
      self.schemeBClickDurationMs = schemeBClickDurationMs
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
