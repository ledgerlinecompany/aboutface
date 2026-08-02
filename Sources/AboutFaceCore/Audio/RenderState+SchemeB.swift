#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

// §6.2 Scheme B — ARRIVAL HERALD REDESIGN (2026-08-02 tuning round 2d,
// maintainer-approved Option B). Split out of `RenderState+Positional.swift`
// purely for SwiftLint's `file_length`, matching that file's own split-from-
// `RenderState.swift` precedent — but also a genuinely separate signal path
// now, the same reasoning `RenderState+GazeTrim.swift` gives for its own
// split.
//
// **Identity change.** Scheme B used to be a fine-XY-only refinement layer,
// distance-gated so it stayed silent until distance was already right (see
// git history for the pre-round-2d version of this file). Round 2c's trial
// surfaced the failure mode: a trial whose DISTANCE axis happened to finish
// last (XY already perfect, distance still resolving) produced a genuine
// zero-click arrival — the crescendo→cut→chime signature never engaged at
// all, because the old gate demanded distance be right BEFORE any click
// could sound. Maintainer's verdict: **"A cue that sometimes doesn't fire
// teaches you not to trust it."** Scheme B is no longer an XY-only
// refinement cue — it heralds proximity to the FULL three-axis settle
// (horizontal, vertical, AND distance), so the crescendo→cut→chime pairing
// is reliable regardless of which axis happens to finish last.
//
// **The lagging axis governs.** Overall closeness is
// `min(xyCloseness, distanceCloseness)` — see `schemeBSampleIfActive` for
// the exact formulas. Whichever axis is farther from settling holds the
// click rate down; only once BOTH axes are genuinely close does the
// crescendo reach full rate. The old binary "distance must already be
// right" gate is gone: it is subsumed by the `min` — distance far now
// means `distanceCloseness == 0`, so `min(...) == 0` and the layer is
// silent, exactly as before, but smoothly (as distance recovers, clicks
// fade back in) rather than as a hard on/off gate.
//
// **Engage further out, pace the ramp (round-2d pacing feedback).**
// Maintainer, on hearing round-2c's crescendo: "I got them almost
// indistinguishably fast pretty quickly and didn't spend much time hearing
// them very slow. Maybe start even further out with the clicks and
// converge them." Two changes follow directly:
//   1. `schemeBRefinementFraction` widened `0.5 → 0.8` — the engagement
//      envelope now starts much further from center, so there is far more
//      approach distance over which to hear the rate actually climbing.
//   2. NEW `schemeBRateCurve` (default `2.0`): `beatHz = maxBeatHz ·
//      closeness ^ rateCurve`. Squaring keeps the rate low (sparse,
//      countable clicks) through most of the approach and compresses the
//      near-maximum blur into the final instants right before arrival —
//      the same psychoacoustic lesson `Config.AudioPositional
//      .timbreOnsetExponent` already applies to the vertical-timbre
//      crossing (see that field's doc comment): a curve above `1.0` keeps
//      the signal legible longer instead of blurring into ambiguity too
//      early. `rateCurve == 1.0` reproduces the old linear mapping exactly
//      (`closeness ^ 1 == closeness`).
//
// Round 1's Scheme B trial (`p1-scheme-b`,
// `docs/tuning/2026-08-02-convergence-experiment.md`) shipped the ORIGINAL
// design — a fixed reference tone plus a moving tone whose beat frequency
// tracked error, nulling to 0 Hz at zero error — and it came back
// unjudgeable: "I wasn't sure if I was supposed to get it to match the
// other one." The two-tone beat sat in the same register as Scheme A's own
// tonal beacon, so the maintainer (blind to which profile was which)
// couldn't reliably tell the refinement layer apart from the thing it was
// refining — a register collision, not a "does zero-beat nulling work"
// finding. Maintainer's redesign brief: "something more percussive/clicky,
// since we don't use that yet."
//
// Scheme B is now a CLICK TRAIN, not a tone: short, non-tonal noise
// transients (`Config.AudioScheme.schemeBClickDurationMs` — deliberately
// "a few ms," much shorter than `Config.AudioEarcons.FaceLost`'s long noise
// burst) repeating at a rate derived from overall closeness (see above).
// The clicks are non-tonal by construction (filtered noise, no carrier
// pitch), so they can never be mistaken for Scheme A's tonal beacon the way
// the old beat tone could.
//
// Rate ceiling stays `schemeBMaxBeatHz` (default 10 Hz); arrival is still
// dead-zone entry cutting everything (the whole positional layer, B
// included — see `RenderState.mixedSample`) plus the good-zone earcon: the
// crescendo→cut→chime signature is produced entirely by existing structure,
// unchanged by this redesign.
extension RenderState {
  /// One sample's worth of the click-train B-layer, given the already-
  /// computed overall `closeness` (`min(xyCloseness, distanceCloseness)`,
  /// see `schemeBSampleIfActive`). Only called while
  /// `config.scheme.schemeBEnabled`, Scheme A is `.panPitch`, and
  /// `closeness > 0` — i.e. BOTH axes are within their respective
  /// engagement envelopes. `closeness` is always `0...1` by construction, so
  /// `beatHz` below is never negative.
  func schemeBSample(sampleRate: Double, closeness: Double) -> Float {
    // PARKING-SENSOR polarity (round-2 maintainer directive — "I was
    // expecting speed up = good until you converge on perfect"): click
    // rate rises as the lagging axis approaches its own full-rate
    // threshold, matching the proximity-alert schema everyone already
    // knows (parking sensors, Geiger counters). Rate is 0 the instant
    // either axis is at (or beyond) its own engagement threshold — the
    // layer fades in from silence, no pop at either envelope's edge — and
    // maxes as BOTH axes approach their full-rate thresholds together,
    // where dead-zone entry cuts all positional sound and fires the
    // good-zone earcon: the arrival is a crescendo → cut → chime, produced
    // entirely by existing structure.
    //
    // Round-2d pacing: `closeness ^ schemeBRateCurve` (default exponent
    // `2.0`) replaces the old bare `closeness` — see this file's top-level
    // doc comment for the full "why" (same curve-above-linear lesson as
    // `Config.AudioPositional.timbreOnsetExponent`). `closeness == 0` and
    // `closeness == 1` are fixed points for any exponent (`0^e == 0`,
    // `1^e == 1`), so the silent-at-engagement and full-rate-at-arrival
    // boundaries are unchanged by the curve; only the shape of the ramp
    // between them changes.
    let rateCurve = config.scheme.schemeBRateCurve
    let shapedCloseness = pow(max(0, min(1, closeness)), rateCurve)
    let beatHz = Double(config.scheme.schemeBMaxBeatHz) * shapedCloseness

    let previousPhase = schemeBClickPhase
    schemeBClickPhase = advancedPhase(schemeBClickPhase, freqHz: beatHz, sampleRate: sampleRate)

    // `advancedPhase` wraps at 2π; a decrease this sample means a new click
    // cycle just started — (re)trigger the transient by resetting the
    // elapsed-sample counter. `beatHz <= 0` (either axis at or beyond its
    // own engagement threshold) never advances the phase, so the layer
    // engages from genuine silence at the boundary; maximum rate is reached
    // just before dead-zone entry cuts everything. The increment is
    // saturating (never past `Int.max`, so never overflows) rather than
    // unconditional `+= 1`: `schemeBClickElapsedSamples` defaults to
    // `Int.max` (see its doc comment on `RenderState`) precisely so a fresh
    // renderer never spuriously clicks before any real trigger, and an
    // unconditional increment would overflow-trap on the very first sample.
    if beatHz > 0, schemeBClickPhase < previousPhase {
      schemeBClickElapsedSamples = 0
    } else if schemeBClickElapsedSamples < .max {
      schemeBClickElapsedSamples += 1
    }

    return clickSample(sampleRate: sampleRate)
  }

  /// The click transient itself: a short, sharply-enveloped burst of white
  /// noise — non-tonal by construction (no carrier frequency at all, unlike
  /// every other voice/ingredient in this renderer) — using
  /// `AudioSynthesis.humpEnvelope` so the transient starts and ends at
  /// exactly zero amplitude, the same click-free guarantee earcon voices
  /// rely on. `schemeBClickRng` is `RenderState`-owned stored state (same
  /// no-allocation pattern as `noiseSeedCounter`/the phase accumulators)
  /// advanced every sample the click is sounding, not reseeded per-click —
  /// a continuously-running noise stream sampled through a short window,
  /// rather than a fresh PRNG each hit.
  private func clickSample(sampleRate: Double) -> Float {
    let cfg = config.scheme
    let durationSeconds = max(0, cfg.schemeBClickDurationMs) / 1000
    guard durationSeconds > 0, sampleRate > 0 else { return 0 }
    let t = Double(schemeBClickElapsedSamples) / sampleRate
    guard t <= durationSeconds else { return 0 }

    let envelope = AudioSynthesis.humpEnvelope(t: t, duration: durationSeconds)
    let noise = AudioSynthesis.whiteNoiseSample(&schemeBClickRng)
    return Float(envelope) * noise * Float(cfg.schemeBClickGain)
  }

  /// `(engageAt - value) / (engageAt - fullRateAt)`, clamped to `0...1` —
  /// the shared "how close is this one axis to its own full-rate
  /// threshold" computation both `xyCloseness` and `distanceCloseness`
  /// reduce to in `schemeBSampleIfActive`, differing only in which
  /// magnitude and which pair of thresholds they plug in. `value` and
  /// `engageAt` are always `>= 0` by construction at both call sites (a
  /// Euclidean norm and an absolute value respectively), but the formula
  /// itself does not depend on that. `rampSpan` floors at `0.001` so a
  /// degenerate config (`engageAt <= fullRateAt`) can never divide by zero
  /// or a negative span; in that case `(engageAt - value)` is `<= 0` for
  /// any `value >= engageAt`, and clamping still yields `0`, matching the
  /// intent ("no meaningful ramp configured ⇒ no click engagement").
  private func closenessFraction(value: Float, engageAt: Float, fullRateAt: Float) -> Double {
    let rampSpan = max(0.001, engageAt - fullRateAt)
    return Double(min(1, max(0, (engageAt - value) / rampSpan)))
  }

  /// §6.2: "Schemes A and B compose; B is a refinement layer" — Scheme B
  /// only ever layers on top of Scheme A, never Scheme C. Returns `nil`
  /// when Scheme B shouldn't sound this sample.
  ///
  /// **Lagging-axis governance (round-2d "arrival herald" redesign).**
  /// Scheme B no longer heralds fine-XY refinement alone — it heralds
  /// proximity to the FULL three-axis settle, so overall closeness is
  /// `min(xyCloseness, distanceCloseness)`: whichever axis is farther from
  /// its own full-rate threshold holds the whole layer back. This
  /// subsumes the old binary "distance must already be right" gate —
  /// distance far now drives `distanceCloseness` to `0`, so `min(...)` is
  /// `0` and the layer is silent, exactly as before but smoothly (fading
  /// back in as distance recovers) rather than as a hard on/off check.
  ///
  /// - `xyCloseness`: `magnitude` is the existing 2D total error norm
  ///   (`totalErrorMagnitude()`); engages at `schemeBRefinementFraction ×
  ///   positional.errorRange` and reaches full rate at the existing
  ///   `schemeBFullRateAtError` (≈ the dead-zone corner, unchanged by this
  ///   redesign).
  /// - `distanceCloseness`: `|currentTarget.distanceError|`; engages at the
  ///   NEW `schemeBDistanceEngageError` (default `0.15`, half of
  ///   `distance.errorRange`) and reaches full rate at
  ///   `distance.audibleRampStartError` — the distance-audibility ramp's
  ///   own "genuinely wrong" threshold (`Config.AudioDistance
  ///   .audibleRampStartError`'s doc comment), reused here rather than
  ///   duplicated as a twin field: both mark the same "distance is
  ///   basically settled" boundary, so reading it straight from
  ///   `config.distance` keeps the two in lockstep by construction instead
  ///   of by convention.
  func schemeBSampleIfActive(sampleRate: Double) -> Float? {
    guard config.scheme.schemeBEnabled, config.scheme.positional == .panPitch else { return nil }

    let magnitude = totalErrorMagnitude()
    let engageXY =
      Float(config.scheme.schemeBRefinementFraction) * Float(config.positional.errorRange)
    let fullRateXY = Float(config.scheme.schemeBFullRateAtError)
    let xyCloseness = closenessFraction(
      value: magnitude, engageAt: engageXY, fullRateAt: fullRateXY)

    let distanceMagnitude = Float(abs(currentTarget.distanceError))
    let engageDistance = Float(config.scheme.schemeBDistanceEngageError)
    let fullRateDistance = Float(config.distance.audibleRampStartError)
    let distanceCloseness = closenessFraction(
      value: distanceMagnitude, engageAt: engageDistance, fullRateAt: fullRateDistance)

    let closeness = min(xyCloseness, distanceCloseness)
    guard closeness > 0 else { return nil }
    return schemeBSample(sampleRate: sampleRate, closeness: closeness)
  }
}
