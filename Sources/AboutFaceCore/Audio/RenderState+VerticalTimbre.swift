#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

// §6.2 vertical-axis timbre differentiation — split out of
// `RenderState+Positional.swift` purely for SwiftLint's `file_length`,
// matching that file's own split-from-`RenderState.swift` precedent (and
// `AnalysisEngine`/`AnalysisEngine+Framing.swift` before it). Called only
// from `RenderState+Positional.swift`'s `panPitchSample`/`sequentialSample`,
// so everything here stays `private` except where noted.
extension RenderState {
  /// §6.2 vertical-axis timbre differentiation (2026-08-02 maintainer
  /// tuning-session directive): "purity for center, an ingredient that
  /// grows with error for each direction" — a bare target PITCH relies on
  /// memory, but stereo center (and now timbral purity) is pre-attentively
  /// obvious without it. A timbre SWITCH at center would be exactly as
  /// unlearnable as the bare pitch it replaces (the 50/50 point has no
  /// identity); purity-at-center gives the target an intrinsic sonic
  /// identity instead, the same trick Scheme B's null uses.
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
  /// 2)`), so it gets its own independently-advanced `subOctavePhase`.
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
  ///
  /// **Onset curve (2026-08-02 first live convergence-trial finding): "huge
  /// jump in perceived pitch from too low to too high."** Crossing vertical
  /// center quickly used to swap brightness ↔ darkness at a rate LINEAR in
  /// `|normalized|`, so a fast crossing still carried an audible amount of
  /// one ingredient right up to the flip — see
  /// `Config.AudioPositional.timbreOnsetExponent`'s doc comment for the full
  /// reasoning. `pow(magnitude, exponent)` (default exponent `2.0`) replaces
  /// the bare `magnitude` both sides use below, applied identically to
  /// `brightnessMix` and `darknessMix` — the crossing is symmetric, so the
  /// curve must be too. `exponent == 1.0` reproduces the exact old linear
  /// behavior; `magnitude == 0` and `magnitude == 1` are fixed points for
  /// any exponent (`0^e == 0`, `1^e == 1`), so purity-at-center and
  /// full-scale character at the outer edge of `errorRange` are both
  /// unchanged.
  func verticalTimbreMix(
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
    let onsetExponent = Float(cfg.timbreOnsetExponent)
    let brightnessMagnitude = onsetShaped(max(0, normalized), exponent: onsetExponent)
    let darknessMagnitude = onsetShaped(max(0, -normalized), exponent: onsetExponent)
    let brightnessMix = Float(cfg.maxBrightnessMix) * brightnessMagnitude
    let darknessMix = Float(cfg.maxDarknessMix) * darknessMagnitude

    let brightened = brightnessComponent(
      pureCarrier: pureCarrier, intensity: brightnessMix, freqHz: freqHz, sampleRate: sampleRate)
    let subOctave = Float(sin(subOctavePhase))
    return brightened + darknessMix * subOctave
  }

  /// `pow(magnitude, exponent)`, guarding the one input `pow` does not
  /// handle gracefully for this use (a zero base with a zero exponent would
  /// be `1`, not `0` — never actually reachable via `Config`-validated
  /// `timbreOnsetExponent` values in practice, but a stray `0` config value
  /// should still collapse to silence rather than a discontinuous full-mix
  /// spike at `magnitude == 0`). `magnitude` is always `0...1` here
  /// (`max(0, ±normalized)`, itself already clamped to `-1...1` above).
  private func onsetShaped(_ magnitude: Float, exponent: Float) -> Float {
    guard magnitude > 0 else { return 0 }
    return pow(magnitude, exponent)
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
}
