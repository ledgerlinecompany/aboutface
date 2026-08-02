#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

// Positional sonification (§6.2) — split out of `RenderState.swift` purely
// for SwiftLint's `file_length`, matching the `AnalysisEngine`/
// `AnalysisEngine+Framing.swift` split precedent elsewhere in this package.
// `positionalSample`/`totalErrorMagnitude`/`schemeBSample` are called from
// `RenderState.swift`'s `mixedSample`/`schemeBSampleIfActive`, so they (and
// the stored properties they touch) are `internal`, not `private` — see
// `RenderState.swift`'s stored-property doc comment for why that's still
// just as invisible outside `AboutFaceCore`.
extension RenderState {
  /// **Beacon principle (2026-08-01 maintainer directive).** The sound is
  /// positioned at the TARGET, not at the subject's current error: moving
  /// to "center" the sound also moves the subject into position. Concretely,
  /// pan and pitch encode the *negated* error whenever
  /// `config.positional.beaconPolarity` is `true` (the shipped default) —
  /// see `Config.AudioPositional.beaconPolarity`'s doc comment for the
  /// full reasoning and the `AudioRendererBeaconPolarityTests` for the
  /// hand-derived acceptance case.
  func positionalSample(sampleRate: Double) -> (Float, Float) {
    let cfg = config.positional
    let signMultiplier: Float = cfg.beaconPolarity ? -1 : 1
    let (effectiveMinHz, effectiveMaxHz) = effectivePitchRange()

    switch config.scheme.positional {
    case .panPitch:
      return panPitchSample(
        signMultiplier: signMultiplier, minHz: effectiveMinHz, maxHz: effectiveMaxHz,
        sampleRate: sampleRate)
    case .sequential:
      return sequentialSample(
        signMultiplier: signMultiplier, minHz: effectiveMinHz, maxHz: effectiveMaxHz,
        sampleRate: sampleRate)
    }
  }

  private func panPitchSample(
    signMultiplier: Float, minHz: Double, maxHz: Double, sampleRate: Double
  ) -> (Float, Float) {
    let cfg = config.positional
    let pitchRaw = signMultiplier * currentTarget.errorY
    let freq = AudioSynthesis.exponentialFrequency(
      normalized: pitchRaw, range: Float(cfg.errorRange), minHz: minHz, maxHz: maxHz)
    positionalPhase = advancedPhase(positionalPhase, freqHz: freq, sampleRate: sampleRate)

    let amplitude = Float(cfg.toneGain) * distanceGate(sampleRate: sampleRate)
    let carrier = verticalTimbreMix(
      pureCarrier: Float(sin(positionalPhase)), timbreRaw: pitchRaw, freqHz: freq,
      sampleRate: sampleRate)
    let sample = carrier * amplitude

    let panRaw = signMultiplier * currentTarget.errorX
    var panNormalized: Float =
      cfg.errorRange > 0 ? max(-1, min(1, panRaw / Float(cfg.errorRange))) : 0
    if config.outputMode == .speakers {
      panNormalized *= Float(cfg.panSpeakerAttenuation)
    }
    let (leftGain, rightGain) = AudioSynthesis.equalPowerPan(panNormalized)
    return (sample * leftGain, sample * rightGain)
  }

  private func sequentialSample(
    signMultiplier: Float, minHz: Double, maxHz: Double, sampleRate: Double
  ) -> (Float, Float) {
    let cfg = config.positional
    let horizontalRaw = signMultiplier * currentTarget.errorX
    let horizontalNormalized: Float =
      cfg.errorRange > 0 ? max(-1, min(1, horizontalRaw / Float(cfg.errorRange))) : 0
    let threshold = Float(cfg.sequentialAxisThreshold)
    if sequentialOnHorizontal, abs(horizontalNormalized) <= threshold {
      sequentialOnHorizontal = false
    } else if !sequentialOnHorizontal, abs(horizontalNormalized) > threshold {
      sequentialOnHorizontal = true
    }

    let axisRaw = sequentialOnHorizontal ? horizontalRaw : signMultiplier * currentTarget.errorY
    let freq = AudioSynthesis.exponentialFrequency(
      normalized: axisRaw, range: Float(cfg.errorRange), minHz: minHz, maxHz: maxHz)
    positionalPhase = advancedPhase(positionalPhase, freqHz: freq, sampleRate: sampleRate)

    // Distinct waveform per axis (sine horizontal, triangle vertical) so a
    // mono listener can tell which axis is currently "live" without
    // relying on absolute pitch memory — a structural cue on top of the
    // numeric one (§6.2: mono fallback must be "unambiguous"). The vertical
    // axis's "pure" carrier for timbre purposes is this triangle, not a
    // sine — purity-at-center (§6.2 vertical timbre) means "no added
    // brightness/darkness ingredient," not "sine specifically."
    let pureCarrier: Float =
      sequentialOnHorizontal
      ? Float(sin(positionalPhase)) : Float(triangleWave(phase: positionalPhase))
    // Timbre ingredients apply only while the vertical axis is live — while
    // resolving horizontal, `timbreRaw` is pinned to 0 so
    // `verticalTimbreMix` contributes nothing (axis isolation), same as
    // Scheme A's errorX-only case being naturally zero via `pitchRaw`.
    let timbreRaw: Float = sequentialOnHorizontal ? 0 : axisRaw
    let carrier = verticalTimbreMix(
      pureCarrier: pureCarrier, timbreRaw: timbreRaw, freqHz: freq, sampleRate: sampleRate)
    let amplitude = Float(cfg.toneGain) * distanceGate(sampleRate: sampleRate)
    let sample = carrier * amplitude
    return (sample, sample)
  }

  /// §6.2 vertical-axis timbre differentiation (2026-08-02 maintainer
  /// tuning-session directive): "purity for center, an ingredient that
  /// grows with error for each direction" — a bare target PITCH relies on
  /// memory, but stereo center (and now timbral purity) is pre-attentively
  /// obvious without it. A timbre SWITCH at center would be exactly as
  /// unlearnable as the bare pitch it replaces (the 50/50 point has no
  /// identity); purity-at-center gives the target an intrinsic sonic
  /// identity instead, the same trick Scheme B's zero-beat null uses.
  ///
  /// `timbreRaw` MUST be the same post-polarity, pre-clamp quantity the
  /// frequency mapping above derives its `normalized`/`t` from
  /// (`signMultiplier * errorY`, i.e. `pitchRaw`/vertical-axis `axisRaw`) —
  /// never raw `errorY` — so the timbral ingredient can never disagree with
  /// the pitch direction, including when `beaconPolarity` is flipped for
  /// A/B tuning (see `Config.AudioPositional.beaconPolarity`). Hand-derived
  /// sign chain, mirroring the beacon polarity tests:
  ///
  /// `timbreRaw > 0` ⇒ (exponential mapping above) pitch is pushed toward
  /// `maxHz`, i.e. HIGH ⇒ per the beacon principle that means the TARGET is
  /// ABOVE the subject ⇒ blend in BRIGHTNESS (added upper harmonics).
  /// `timbreRaw < 0` ⇒ pitch LOW ⇒ target BELOW ⇒ blend in DARKNESS (added
  /// sub-octave). `timbreRaw == 0` ⇒ both mixes are 0 ⇒ pure carrier only.
  ///
  /// Harmonics (2nd/3rd) need no separate phase accumulator: multiplying an
  /// already-wrapped phase by an integer stays continuous, because
  /// `sin(k · (phase - 2π)) == sin(k · phase - 2πk) == sin(k · phase)` for
  /// integer `k`. The sub-octave is the opposite case — `phase / 2` is
  /// NOT continuous across a wrap (`sin((phase - 2π) / 2) == -sin(phase /
  /// 2)`), so it gets its own independently-advanced `subOctavePhase`
  /// (same pattern as `schemeBReferencePhase`/`schemeBMovingPhase` being
  /// separate accumulators rather than one derived from the other).
  ///
  /// **Round 2 (2026-08-02 audition feedback):** "The below indicator is
  /// clear, the above indicator is a little less clear. I think maybe
  /// something a little more overdriven? Or mix in a saw or something?" —
  /// the additive 2nd/3rd harmonic blend above (now `BrightnessStyle
  /// .harmonics`) reads as too subtle. Rather than pick a replacement by
  /// guessing, the brightness ingredient's synthesis CHARACTER is now
  /// selectable via `Config.AudioPositional.brightnessStyle` (§0/§16: tune
  /// by ear, let the maintainer audition and choose) — see
  /// `brightnessComponent` below. The darkness (sub-octave) side is
  /// deliberately untouched: the maintainer only flagged the above
  /// indicator as unclear.
  private func verticalTimbreMix(
    pureCarrier: Float, timbreRaw: Float, freqHz: Double, sampleRate: Double
  ) -> Float {
    let cfg = config.positional
    // Always advanced (even when this sample's mixes are both 0) so the
    // sub-octave stays phase-continuous with the tracked frequency instead
    // of jumping when an ingredient re-engages — the same reasoning
    // `positionalPhase`/`pulsePhase` always advancing already relies on
    // elsewhere in this file.
    subOctavePhase = advancedPhase(subOctavePhase, freqHz: freqHz / 2, sampleRate: sampleRate)
    guard cfg.verticalTimbreEnabled, cfg.errorRange > 0 else { return pureCarrier }

    let normalized = max(-1, min(1, timbreRaw / Float(cfg.errorRange)))
    let brightnessMix = Float(cfg.maxBrightnessMix) * max(0, normalized)
    let darknessMix = Float(cfg.maxDarknessMix) * max(0, -normalized)

    let brightened = brightnessComponent(
      pureCarrier: pureCarrier, intensity: brightnessMix, freqHz: freqHz, sampleRate: sampleRate)
    let subOctave = Float(sin(subOctavePhase))
    return brightened + darknessMix * subOctave
  }

  /// The "target above" brightness ingredient, dispatched on
  /// `Config.AudioPositional.brightnessStyle` (§6.2 round-2 audition
  /// feedback — see `verticalTimbreMix`'s doc comment above for the full
  /// context). `intensity` is `brightnessMix` from `verticalTimbreMix`:
  /// already `0` at zero vertical error and scaled up to `maxBrightnessMix`
  /// at the outer edge of `errorRange`, shared verbatim by every style —
  /// which is what makes "purity at center" hold for all three the same
  /// way: `intensity == 0` collapses `.overdrive` and `.saw` to an exact
  /// (not approximate) identity crossfade, and zeroes out `.harmonics`'
  /// additive term the same way it always did.
  private func brightnessComponent(
    pureCarrier: Float, intensity: Float, freqHz: Double, sampleRate: Double
  ) -> Float {
    switch config.positional.brightnessStyle {
    case .harmonics:
      // Round 1's baseline, unchanged: additive blend of the 2nd and 3rd
      // harmonic of the vertical carrier's own phase. Kept verbatim so it
      // stays an honest before/after comparison point in the audition
      // rather than a moving target.
      let harmonics =
        0.6 * Float(sin(2 * positionalPhase)) + 0.4 * Float(sin(3 * positionalPhase))
      return pureCarrier + intensity * harmonics

    case .overdrive:
      return overdriveComponent(pureCarrier: pureCarrier, intensity: intensity)

    case .saw:
      let saw = polyBlepSaw(phase: positionalPhase, freqHz: freqHz, sampleRate: sampleRate)
      return pureCarrier + intensity * (saw - pureCarrier)
    }
  }

  /// Waveshapes `pureCarrier` with a gain-normalized `tanh` drive
  /// (`tanh(drive · x) / tanh(drive)`) — the same `tanh` primitive
  /// `AudioSynthesis.softClip` applies to the final mix, but gain-divided
  /// by `tanh(drive)` here (softClip doesn't need that: its job is
  /// asymptotic ceiling-limiting, not a normalized per-sample waveshape),
  /// crossfaded in by `intensity`.
  ///
  /// The crossfade (not just `drive → 1`) is what makes zero intensity an
  /// EXACT identity pass: `tanh(drive · x) / tanh(drive)` is not itself the
  /// identity function at any finite `drive` (e.g. at `drive == 1`,
  /// `x == 0.5` maps to `tanh(0.5) / tanh(1) ≈ 0.607`, not `0.5`), so
  /// relying on `drive → 1` alone would leave a small but real residual at
  /// center and violate purity-at-center. Crossfading by `intensity`
  /// guarantees `intensity == 0 ⇒ output == pureCarrier`, bit for bit.
  ///
  /// `drive` itself ramps from `1` (mild) up to
  /// `Config.AudioPositional.overdriveMaxDrive` as `intensity` goes from
  /// `0` to `1` (i.e. to `maxBrightnessMix`, since `intensity` is already
  /// scaled by it) — so both the waveshape AND how much of it is mixed in
  /// grow together as the target gets further above, which is what makes
  /// this read as "audibly more overdriven," not subtly so (the round-2
  /// ask).
  ///
  /// `tanh` is an odd function, and `tanh(k · sin(x))` inherits `sin`'s
  /// half-wave antisymmetry (`sin(x + π) == -sin(x)`), so this waveshaper
  /// adds ONLY odd harmonics (3rd, 5th, 7th, ...) of the carrier — never
  /// the 2nd — which is why `AudioRendererBrightnessStyleTests` measures
  /// 3f/5f energy for this style, not 2f. Odd-harmonic energy from `tanh`
  /// rolls off fast (each added harmonic is markedly weaker than the last —
  /// unlike a hard clip's slow ~1/n rolloff), and this renderer's vertical
  /// tone lives in a few-hundred-Hz range against a 48kHz sample rate, so
  /// even `overdriveMaxDrive`'s harshest harmonics stay well below Nyquist.
  /// `tanh` of a sine is smooth but not literally band-limited, so there is
  /// SOME aliasing in principle as drive grows — capping `overdriveMaxDrive`
  /// (default 6) rather than leaving it unbounded is what keeps that
  /// tradeoff inaudible in practice.
  private func overdriveComponent(pureCarrier: Float, intensity: Float) -> Float {
    guard intensity > 0 else { return pureCarrier }
    let maxDrive = max(1, Float(config.positional.overdriveMaxDrive))
    let driveIntensity = min(1, intensity)
    let drive = Double(1 + (maxDrive - 1) * driveIntensity)
    let shaped = Float(tanh(drive * Double(pureCarrier)) / tanh(drive))
    return pureCarrier + intensity * (shaped - pureCarrier)
  }

  /// Band-limited sawtooth via polyBLEP (polynomial band-limited step;
  /// Valimaki & Huovilainen 2007) applied to the naive `2t - 1` ramp driven
  /// by `positionalPhase`/`freqHz` — the same phase accumulator and
  /// frequency the carrier itself uses, so the saw tracks it exactly (same
  /// frequency/phase, per the design brief), needing no accumulator of its
  /// own (unlike the sub-octave darkness ingredient, which does).
  ///
  /// polyBLEP over an additive (Fourier partial-sum) band-limited saw: additive
  /// synthesis needs one `sin` call per partial up to `sampleRate / (2 ·
  /// freqHz)` partials to band-limit correctly — well over 100 partials at
  /// this renderer's ~220-880Hz tone range and 48kHz sample rate — while
  /// polyBLEP is O(1) per sample (a couple of comparisons and multiplies
  /// layered on the phase already being tracked), which is what "runs per
  /// sample, allocation-free, real-time-safe" (§3.1) actually calls for. The
  /// naive (uncorrected) saw is not an option at all — its instantaneous
  /// jump at each cycle aliases broadly across the spectrum; polyBLEP
  /// replaces just the couple of samples nearest each discontinuity with a
  /// polynomial correction approximating the true band-limited transition,
  /// leaving every other sample untouched.
  private func polyBlepSaw(phase: Double, freqHz: Double, sampleRate: Double) -> Float {
    let t = phase / (2 * .pi)  // 0..<1
    let dt = freqHz / sampleRate
    let naive = 2 * t - 1 - polyBlep(t: t, dt: dt)  // naive rising saw, -1...1, BLEP-corrected
    return Float(max(-1, min(1, naive)))
  }

  /// The polyBLEP correction polynomial: nonzero only within a `dt`-wide
  /// window on each side of the saw's discontinuity (`t` near `0` or `1`,
  /// i.e. the phase wraparound) — zero everywhere else, so this only ever
  /// perturbs the handful of samples nearest the jump.
  private func polyBlep(t: Double, dt: Double) -> Double {
    guard dt > 0 else { return 0 }
    if t < dt {
      let x = t / dt
      return x + x - x * x - 1
    } else if t > 1 - dt {
      let x = (t - 1) / dt
      return x * x + x + x + 1
    }
    return 0
  }

  /// §6.2: "speakers mode narrows pan and widens pitch range to
  /// compensate." Widens the min/max span geometrically around
  /// `referenceToneHz` (rather than arithmetically) so the widened range
  /// stays exponential-mapping-compatible.
  private func effectivePitchRange() -> (Double, Double) {
    let cfg = config.positional
    guard config.outputMode == .speakers, cfg.referenceToneHz > 0, cfg.minToneHz > 0,
      cfg.maxToneHz > 0
    else {
      return (cfg.minToneHz, cfg.maxToneHz)
    }
    let reference = cfg.referenceToneHz
    let expansion = cfg.pitchSpeakerRangeExpansion
    let effectiveMin = reference * pow(cfg.minToneHz / reference, expansion)
    let effectiveMax = reference * pow(cfg.maxToneHz / reference, expansion)
    return (effectiveMin, effectiveMax)
  }

  /// §6.2: "Distance maps to pulse rate... never volume." See
  /// `Config.AudioDistance`'s doc comment for why a rate-coded amplitude
  /// gate is not the "volume" the spec rules out. Returns a multiplier in
  /// `[1 - pulseDepth, 1]`.
  private func distanceGate(sampleRate: Double) -> Float {
    let cfg = config.distance
    let magnitude = min(Float(cfg.errorRange), abs(currentTarget.distanceError))
    let t = cfg.errorRange > 0 ? Double(magnitude) / cfg.errorRange : 0
    let rateHz = AudioSynthesis.lerp(cfg.pulseRateMinHz, cfg.pulseRateMaxHz, t)
    pulsePhase = advancedPhase(pulsePhase, freqHz: rateHz, sampleRate: sampleRate)
    let oscillation = 0.5 - 0.5 * cos(pulsePhase)  // 0...1, starts at 0 (gate starts fully open)
    return Float(1 - cfg.pulseDepth * oscillation)
  }

  func totalErrorMagnitude() -> Float {
    (currentTarget.errorX * currentTarget.errorX + currentTarget.errorY * currentTarget.errorY)
      .squareRoot()
  }

  /// §6.2 Scheme B: fixed reference tone plus a moving tone whose offset
  /// from the reference tracks total error magnitude, scaled to reach
  /// `schemeBMaxBeatHz` at the outer edge of the refinement zone and 0 Hz
  /// (a true null) at zero error. Not distance-gated: Scheme B is a fine-XY
  /// null cue, and layering the distance pulse into it would muddy exactly
  /// the precision it exists to provide.
  func schemeBSample(sampleRate: Double, magnitude: Float, zoneLimit: Float) -> Float {
    let schemeCfg = config.scheme
    let positionalCfg = config.positional
    let beatHz = Double(schemeCfg.schemeBMaxBeatHz) * Double(magnitude / zoneLimit)

    schemeBReferencePhase = advancedPhase(
      schemeBReferencePhase, freqHz: positionalCfg.referenceToneHz, sampleRate: sampleRate)
    schemeBMovingPhase = advancedPhase(
      schemeBMovingPhase, freqHz: positionalCfg.referenceToneHz + beatHz, sampleRate: sampleRate)

    let referenceSample = Float(sin(schemeBReferencePhase))
    let movingSample = Float(sin(schemeBMovingPhase))
    // Halved again relative to `toneGain`: a compositing refinement layer,
    // not a replacement for Scheme A's coarse tone.
    return (referenceSample + movingSample) * 0.5 * Float(positionalCfg.toneGain) * 0.5
  }

  private func triangleWave(phase: Double) -> Double {
    let unitPhase = (phase / (2 * .pi)).truncatingRemainder(dividingBy: 1)
    let wrapped = unitPhase < 0 ? unitPhase + 1 : unitPhase
    return 4 * abs(wrapped - 0.5) - 1
  }

  private func advancedPhase(_ phase: Double, freqHz: Double, sampleRate: Double) -> Double {
    var next = phase + 2 * .pi * freqHz / sampleRate
    if next >= 2 * .pi { next -= 2 * .pi }
    if next < 0 { next += 2 * .pi }
    return next
  }
}
