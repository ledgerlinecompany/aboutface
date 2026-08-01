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
    let sample = Float(sin(positionalPhase)) * amplitude

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
    // numeric one (§6.2: mono fallback must be "unambiguous").
    let carrier: Float =
      sequentialOnHorizontal
      ? Float(sin(positionalPhase)) : Float(triangleWave(phase: positionalPhase))
    let amplitude = Float(cfg.toneGain) * distanceGate(sampleRate: sampleRate)
    let sample = carrier * amplitude
    return (sample, sample)
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
