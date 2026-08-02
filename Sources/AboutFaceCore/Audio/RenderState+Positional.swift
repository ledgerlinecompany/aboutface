#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

// Positional sonification (§6.2) — split out of `RenderState.swift` purely
// for SwiftLint's `file_length`, matching the `AnalysisEngine`/
// `AnalysisEngine+Framing.swift` split precedent elsewhere in this package.
// Scheme B's percussive click train lives in `RenderState+SchemeB.swift`;
// the vertical-timbre brightness/darkness synthesis lives in
// `RenderState+VerticalTimbre.swift` — both split out the same way, for the
// same reason. `positionalSample`/`totalErrorMagnitude` are called from
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
    let pitchRaw = quantizedError(
      signMultiplier * currentTarget.errorY, glideState: &quantizationGlideY,
      sampleRate: sampleRate)
    let freq = AudioSynthesis.exponentialFrequency(
      normalized: pitchRaw, range: Float(cfg.errorRange), minHz: minHz, maxHz: maxHz)
    positionalPhase = advancedPhase(positionalPhase, freqHz: freq, sampleRate: sampleRate)

    let amplitude = Float(cfg.toneGain) * distanceGate(sampleRate: sampleRate)
    let carrier = verticalTimbreMix(
      pureCarrier: Float(sin(positionalPhase)), timbreRaw: pitchRaw, freqHz: freq,
      sampleRate: sampleRate)
    let sample = carrier * amplitude

    let panRaw = quantizedError(
      signMultiplier * currentTarget.errorX, glideState: &quantizationGlideX,
      sampleRate: sampleRate)
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

    let axisRaw: Float
    if sequentialOnHorizontal {
      axisRaw = quantizedError(
        horizontalRaw, glideState: &quantizationGlideX, sampleRate: sampleRate)
    } else {
      axisRaw = quantizedError(
        signMultiplier * currentTarget.errorY, glideState: &quantizationGlideY,
        sampleRate: sampleRate)
    }
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

  func totalErrorMagnitude() -> Float {
    (currentTarget.errorX * currentTarget.errorX + currentTarget.errorY * currentTarget.errorY)
      .squareRoot()
  }

  // Not `private`: read from `RenderState+GazeTrim.swift`'s extension too
  // (a different file — see `RenderState.swift`'s stored-property doc
  // comment for why cross-file sharing within this module uses plain
  // `internal` rather than `private`, which is file-scoped). The trim
  // ingredient reuses this exact waveform (crossfaded in as its own
  // "impurity" ingredient) so it needs no accumulator or synthesis
  // primitive of its own beyond the phase it already tracks.
  func triangleWave(phase: Double) -> Double {
    let unitPhase = (phase / (2 * .pi)).truncatingRemainder(dividingBy: 1)
    let wrapped = unitPhase < 0 ? unitPhase + 1 : unitPhase
    return 4 * abs(wrapped - 0.5) - 1
  }

  // Not `private`: same reasoning as `triangleWave` above —
  // `RenderState+GazeTrim.swift` needs the identical phase-wrapping
  // arithmetic for its own (disjoint) phase accumulator.
  func advancedPhase(_ phase: Double, freqHz: Double, sampleRate: Double) -> Double {
    var next = phase + 2 * .pi * freqHz / sampleRate
    if next >= 2 * .pi { next -= 2 * .pi }
    if next < 0 { next += 2 * .pi }
    return next
  }
  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Snaps a post-polarity error to `errorQuantizationStep` multiples
  /// (`0` = continuous pass-through). Applied AFTER the polarity sign, so
  /// quantization can never flip the beacon's side; round-to-nearest makes
  /// zero a step center, so near-center snaps to true purity.
  ///
  /// **Quantization glide (2026-08-02 action round, item 2).** Rather than
  /// returning the snapped target directly, this slews `glideState` (an
  /// axis-specific `RenderState`-owned accumulator — `quantizationGlideX`
  /// for pan/horizontal, `quantizationGlideY` for pitch/vertical, passed in
  /// by the caller) toward it — see `glidedToward` below for the slew
  /// itself and `Config.AudioPositional.quantizationGlideMs`'s doc comment
  /// for the full design rationale. When `step <= 0` (the continuous case)
  /// this returns `value` immediately WITHOUT touching `glideState` at
  /// all — the continuous render path is therefore byte-identical
  /// regardless of `quantizationGlideMs`, exercised by
  /// `AudioRendererQuantizationGlideTests.continuousPathUnaffectedByGlide`.
  private func quantizedError(_ value: Float, glideState: inout Float, sampleRate: Double)
    -> Float
  {
    // swiftlint:enable opening_brace
    let step = Float(config.positional.errorQuantizationStep)
    guard step > 0 else { return value }
    let target = (value / step).rounded() * step
    glideState = glidedToward(
      target: target, current: glideState, step: step,
      sampleRate: sampleRate)
    return glideState
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Linear slew: moves `current` toward `target` by at most
  /// `step / (quantizationGlideMs / 1000) / sampleRate` per sample — i.e. a
  /// full one-step jump takes `quantizationGlideMs` to traverse, regardless
  /// of how many steps `target` actually is from `current` (crossing
  /// several steps just takes proportionally longer, at the same rate) —
  /// and snaps EXACTLY onto `target` the instant it is within one sample's
  /// travel distance, rather than approaching it asymptotically. That exact
  /// convergence is what lets settled output be bit-identical to the
  /// hard-quantized (no-glide) case, including at `target == 0` (see
  /// `AudioRendererQuantizationGlideTests
  /// .settledOutputMatchesHardQuantized`/`.convergesExactlyToZero`).
  /// `quantizationGlideMs <= 0` disables the glide (instant jump to
  /// `target`), matching this file's "0 disables" convention elsewhere
  /// (`effectivePitchRange`, `RenderState+GazeTrim.swift`'s `onsetRampMs`).
  private func glidedToward(target: Float, current: Float, step: Float, sampleRate: Double)
    -> Float
  {
    // swiftlint:enable opening_brace
    let glideMs = config.positional.quantizationGlideMs
    guard glideMs > 0, sampleRate > 0 else { return target }
    let secondsPerStep = glideMs / 1000
    let maxDelta = Float(Double(step) / (secondsPerStep * sampleRate))
    guard maxDelta > 0 else { return target }
    let diff = target - current
    if abs(diff) <= maxDelta { return target }
    return current + (diff > 0 ? maxDelta : -maxDelta)
  }
}
