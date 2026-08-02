import Foundation

/// §6.2 distance-→pulse mapping (round-4 directional character) — split from
/// `RenderState+Positional.swift` purely for SwiftLint's `file_length`
/// limit; still `RenderState`'s own real-time render-path implementation.
extension RenderState {

  /// §6.2: "Distance maps to pulse rate... never volume." See
  /// `Config.AudioDistance`'s doc comment for why a rate-coded amplitude
  /// gate is not the "volume" the spec rules out. Returns a multiplier in
  /// `[1 - depth · t, 1]` (per-side depth, see round-4b note below), `t` being `|distanceError|` normalized to
  /// `errorRange` (`0` at target, `1` at the outer edge).
  ///
  /// **Directional pulse character (§6.2 round-4).** Rate alone only ever
  /// encoded MAGNITUDE; rate still tracks `|distanceError|` exactly as
  /// before, but the dip SHAPE now also tracks the SIGN, behind
  /// `Config.AudioDistance.directionalPulseEnabled` (default `true`;
  /// `false` ⇒ single legacy shape both signs): `distanceError > 0` (too
  /// close) raises `oscillation` (`sin²(pulsePhase / 2)`, `0...1`) to
  /// `closePulseSharpness` — `sin^(2k)` stays near `0` (gate near `1`) most
  /// of the cycle, rising sharply only near `pulsePhase == π`: a brief,
  /// narrow "chop." `distanceError <= 0` (too far) and the disabled case
  /// keep the unmodified, symmetric `oscillation` — a slow "swell." See
  /// `AudioRendererDistanceDirectionTests` for the hand-derived duty-cycle
  /// gap this produces.
  ///
  /// **Purity anchor.** Before round 4, `pulseRateMinHz` (default `1`, not
  /// `0`) left the gate oscillating at full `pulseDepth` even at zero
  /// distance error. Fixed by scaling the DEPTH by `t` too: at `t == 0` the
  /// multiplier is `1 - 0 · shaped == 1` for every phase/branch — the same
  /// "purity at center" trick `verticalTimbreMix` relies on.
  ///
  /// **Sign-flip continuity.** `pulsePhase` always advances, never resets
  /// (as elsewhere here), so switching shape branches mid-cycle at a sign
  /// flip could still jump — except the flip only happens as
  /// `distanceError` crosses zero, exactly where `t → 0` pins EITHER
  /// branch's output within `pulseDepth · t` of `1`. No crossfade needed:
  /// the purity anchor's depth-scaling is what makes the flip click-free
  /// (`AudioRendererDistanceDirectionTests.signFlipStaysContinuous`).
  func distanceGate(sampleRate: Double) -> Float {
    let cfg = config.distance
    let distanceError = currentTarget.distanceError
    let magnitude = min(Float(cfg.errorRange), abs(distanceError))
    let t = cfg.errorRange > 0 ? Double(magnitude) / cfg.errorRange : 0
    let rateHz = AudioSynthesis.lerp(cfg.pulseRateMinHz, cfg.pulseRateMaxHz, t)
    pulsePhase = advancedPhase(pulsePhase, freqHz: rateHz, sampleRate: sampleRate)
    let oscillation = 0.5 - 0.5 * cos(pulsePhase)  // 0...1, starts at 0 (gate starts fully open)

    // Round-4b: per-side depth. The close side's chops cut nearly to
    // silence (closePulseDepth, default 0.95); the far side's swell stays
    // shallow (farPulseDepth, default 0.4) — depth contrast is the
    // direction cue, rate remains the urgency cue. Continuity at the sign
    // flip is unaffected: both sides' depth still scales by t, which is 0
    // exactly where the branch (and depth constant) switches.
    let shaped: Double
    let depth: Double
    if cfg.directionalPulseEnabled, distanceError > 0 {
      let sharpness = max(0.1, cfg.closePulseSharpness)
      shaped = pow(oscillation, sharpness)
      depth = cfg.closePulseDepth
    } else {
      shaped = oscillation
      depth = cfg.directionalPulseEnabled ? cfg.farPulseDepth : cfg.closePulseDepth
    }
    // Round-4c audibility law: depth ramps 0→1 between the audible-ramp
    // start (≈ the distance dead-zone edge) and start × multiplier, NOT
    // proportionally over the full errorRange — a near-threshold error
    // now sounds like the real thing, not a 6% wobble (maintainer trial
    // session 2: "Still didn't hear any of the cuing for distance").
    // Rate (above) still spans the full errorRange as the urgency cue.
    // Continuity: rampT is 0 at/below the start threshold — which covers
    // the sign flip at zero — and piecewise-linear, so no jumps.
    let start = max(0.0, cfg.audibleRampStartError)
    let span = start * (max(1.0, cfg.audibleRampMultiplier) - 1.0)
    let rampT: Double
    if Double(magnitude) <= start {
      rampT = 0
    } else if span <= 0 {
      rampT = 1
    } else {
      rampT = min(1, (Double(magnitude) - start) / span)
    }
    return Float(1 - depth * rampT * shaped)
  }
}
