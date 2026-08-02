// §6.2 Scheme B — PERCUSSIVE REDESIGN (2026-08-02 convergence-experiment
// action round, item 3). Split out of `RenderState+Positional.swift` purely
// for SwiftLint's `file_length`, matching that file's own split-from-
// `RenderState.swift` precedent — but also a genuinely separate signal path
// now, the same reasoning `RenderState+GazeTrim.swift` gives for its own
// split.
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
// burst) repeating at a rate equal to what the old beat frequency would
// have been (`schemeBMaxBeatHz`, linear over the refinement zone, reaching
// that rate at the outer edge and dropping to 0 — i.e. no clicks at all,
// true silence — at zero error). The clicks are non-tonal by construction
// (filtered noise, no carrier pitch), so they can never be mistaken for
// Scheme A's tonal beacon the way the old beat tone could.
//
// Two orthogonal "you're there" channels once composed with the quantized
// beacon (`AudioPositional.errorQuantizationStep`, default `0.03` as of
// this same action round): the beacon's tonal PURITY (snap to a pure
// center tone) and Scheme B's rhythmic SILENCE (clicks stop entirely) both
// mean the same thing — "you are centered" — through two independent
// perceptual channels, timbre and rhythm. See
// `Fixtures/tuning-profiles/README.md`'s `p6`/`p7` for the re-trial this
// composition motivates.
extension RenderState {
  /// One sample's worth of the click-train B-layer. Only called (via
  /// `RenderState.schemeBSampleIfActive`) while
  /// `config.scheme.schemeBEnabled` and `magnitude <= zoneLimit` — i.e.
  /// strictly inside the refinement zone. `magnitude`/`zoneLimit` are
  /// always `>= 0` by construction (`totalErrorMagnitude()` is a Euclidean
  /// norm; `zoneLimit` is a nonnegative fraction of `errorRange`), so
  /// `beatHz` below is never negative. Not distance-gated, same as the
  /// pre-redesign version: Scheme B is a fine-XY refinement cue, and
  /// layering the distance pulse into it would muddy exactly the precision
  /// it exists to provide.
  func schemeBSample(sampleRate: Double, magnitude: Float, zoneLimit: Float) -> Float {
    let beatHz = Double(config.scheme.schemeBMaxBeatHz) * Double(magnitude / zoneLimit)

    let previousPhase = schemeBClickPhase
    schemeBClickPhase = advancedPhase(schemeBClickPhase, freqHz: beatHz, sampleRate: sampleRate)

    // `advancedPhase` wraps at 2π; a decrease this sample means a new click
    // cycle just started — (re)trigger the transient by resetting the
    // elapsed-sample counter. `beatHz <= 0` (exactly at the null) never
    // advances the phase at all (`advancedPhase` is a no-op at `freqHz ==
    // 0`), so it can never wrap and never (re)triggers — true silence at
    // the null, the same "silence at center" property the old zero-beat
    // design had, now produced by rhythm instead of pitch. The increment is
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
}
