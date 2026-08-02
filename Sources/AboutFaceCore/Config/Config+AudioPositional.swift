/// `Config.AudioPositional` — split from `Config+Audio.swift` purely for
/// SwiftLint's `file_length` limit (same pattern as
/// `Config+AudioDistance.swift` / `Config+AudioGazeTrim.swift` /
/// `Config+AudioEarcons.swift`).
extension Config {
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
    /// **Timbre onset curve (§6.2 extension, 2026-08-02 first live
    /// convergence-trial finding): "huge jump in perceived pitch from too
    /// low to too high."** Crossing vertical center quickly used to swap the
    /// brightness/darkness ingredient at a rate LINEAR in `|normalized
    /// timbreRaw|` (`mix = maxMix · |normalized|`), so a fast crossing near
    /// center still carried a perceptible amount of one ingredient right up
    /// to the flip — read as an abrupt octave-scale timbral (and, because
    /// pitch is also swinging fastest near center, perceived-pitch) jump.
    /// `mix = maxMix · |normalized|^timbreOnsetExponent` instead: at `1.0`
    /// (the old behavior, kept selectable for A/B) the ramp is linear; above
    /// `1.0` the ingredient's onset is SUPERLINEAR, so near center both
    /// sides stay nearly pure (e.g. at `|normalized| == 0.5`,
    /// exponent `2.0` gives `0.5² = 0.25` of `maxMix`, a quarter, not half)
    /// and the full-scale character at the outer edge of `errorRange` is
    /// unchanged (`1.0^exponent == 1.0` for any exponent). Default `2.0` —
    /// a starting point (§0), not a fixed constant. Applies identically to
    /// both `maxBrightnessMix` and `maxDarknessMix` in
    /// `RenderState.verticalTimbreMix` — the crossing is symmetric, so the
    /// curve must be too, or one side would still jump more sharply than
    /// the other.
    public var timbreOnsetExponent: Double
    /// Sonification quantization (2026-08-02 experiment). `0` = continuous
    /// beacon; `> 0` snaps the post-polarity error driving pan/pitch to
    /// multiples of this step — discrete audible levels. **Default `0.03`
    /// as of the action round following the 2026-08-02 convergence
    /// experiment** (`docs/tuning/2026-08-02-convergence-experiment.md`):
    /// across five trial profiles plus a practiced baseline, `p5
    /// -quantized-fine` (step `0.03`) swept BOTH speed (median settle 7.9s,
    /// fastest of any profile) AND steadiness (`.0241`, the lowest —
    /// meaning the least residual wobble once settled) — a coarser step
    /// (`p4`, `0.08`) nearly abolished overshoots (1, vs. 8-15 elsewhere)
    /// but lost on steadiness, so `0.03` is the shipped middle ground, not
    /// the most-aggressive option. The practiced control (`p0-again`) ran
    /// LAST in the trial order specifically to rule out "quantized won
    /// because practice, not because quantized" — it still lost on both
    /// axes. Unrelated to `Config.Display` (which steps the DISPLAY, not
    /// the sound). See `quantizationGlideMs` for how the discrete jump this
    /// produces is now smoothed into an audible glide rather than a hard
    /// step.
    public var errorQuantizationStep: Double
    /// **Quantization glide (2026-08-02 action round, item 2 — maintainer
    /// design direction: "separate true quantization from the way the
    /// sounds output").** Both quantized trial profiles (`p4`, `p5`) were
    /// subjectively "jumpy": the rendered tone hard-stepped between
    /// quantized levels with no transition. This field decouples the two
    /// concerns the maintainer's phrasing names — `errorQuantizationStep`
    /// still defines the discrete TARGET levels (unchanged, still what
    /// determines "you're there"); this field controls how the RENDERED
    /// value gets from one level to the next: slewed at a rate that
    /// traverses one `errorQuantizationStep` in `quantizationGlideMs`
    /// milliseconds, rather than jumping instantly. The slew always
    /// converges EXACTLY onto the quantized target (never asymptotically),
    /// so the "you're there" purity snap `errorQuantizationStep` exists for
    /// is preserved bit-for-bit once settled — see
    /// `RenderState.quantizedError`/`glidedToward`. Only engaged while
    /// `errorQuantizationStep > 0`; with the continuous default off
    /// (`errorQuantizationStep == 0`) this field has no effect at all, and
    /// the continuous render path stays byte-identical regardless of its
    /// value (see `AudioRendererQuantizationGlideTests
    /// .continuousPathUnaffectedByGlide`). `<= 0` disables the glide
    /// (instant jump — the pre-glide behavior), matching this file's "0
    /// disables" convention elsewhere (`effectivePitchRange`,
    /// `RenderState+GazeTrim.swift`'s `onsetRampMs`). Default `80`
    /// (milliseconds per step) once `errorQuantizationStep` is nonzero —
    /// a starting point (§0), not measured against the corpus yet.
    public var quantizationGlideMs: Double
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
      timbreOnsetExponent: Double,
      overdriveMaxDrive: Double,
      errorQuantizationStep: Double = 0,
      quantizationGlideMs: Double = 0
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
      self.timbreOnsetExponent = timbreOnsetExponent
      self.overdriveMaxDrive = overdriveMaxDrive
      self.errorQuantizationStep = errorQuantizationStep
      self.quantizationGlideMs = quantizationGlideMs
    }
  }
}
