#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// **Gaze trim (tuning round 5, maintainer-designed audition prototype —
/// `Config.AudioGazeTrim`, default OFF).** Split out of
/// `RenderState+Positional.swift` (rather than folded into it) purely
/// because it is a genuinely separate signal path, not a variation on the
/// beacon's own mapping — matching the `RenderState`/`RenderState+
/// Positional.swift` split precedent. `FeedbackRouter+GazeTrim.swift`
/// decides WHEN this plays (Setup mode, confirmed good zone,
/// `Config.AudioGazeTrim.enabled`); this file decides what it SOUNDS like.
///
/// ## Different in kind, on purpose
///
/// The task brief's hard requirement: trim must never be mistakable for the
/// positional beacon, so a user always knows which loop they're in.
/// Concretely, three independent differences from `positionalSample`:
///
/// - **Register.** `Config.AudioGazeTrim.minHz`/`maxHz` (default 1600-2400
///   Hz) sit entirely above `AudioPositional.minToneHz`/`maxToneHz`
///   (default 220-880 Hz, up to ~1244 Hz once `.speakers`
///   `pitchSpeakerRangeExpansion` widens it) — a "soft high sine," not a
///   variation on the beacon's own few-hundred-Hz tone.
/// - **Gain.** `Config.AudioGazeTrim.gain` (default `0.05`) is its own
///   field, well below `AudioPositional.toneGain` (default `0.2`) — see
///   `AudioRendererGazeTrimTests.trimIsQuieterThanBeaconAtDefaults`.
/// - **Onset.** The beacon starts at full `toneGain` instantly on
///   activation (a documented, pre-existing limitation — see
///   `RenderState.mixedSample`'s NOTE). Trim instead ramps in over
///   `Config.AudioGazeTrim.onsetRampMs` (`gazeTrimRampGain`, reset in
///   `mixedSample` whenever trim isn't the active branch) — deliberately
///   the OPPOSITE posture, so entering the good zone is never punctuated by
///   a pop.
///
/// ## Sign derivation (beacon-polarity philosophy, fixed — no A/B flag)
///
/// Both axes reuse the beacon's own "turn toward the sound" principle
/// (`AudioPositional.beaconPolarity`'s doc comment) with a fixed polarity
/// (this is a single-purpose prototype, not a shipped, user-facing scheme —
/// no `beaconPolarity`-style toggle is exposed):
///
/// `yawDeviationDegrees > 0` ⇒ head turned RIGHT of neutral ⇒ correct by
/// turning LEFT ⇒ tone comes from the LEFT ⇒ `panRaw = -yawDeviationDegrees`
/// negative ⇒ `equalPowerPan` favors the left channel. Hand-derived
/// acceptance case: `AudioRendererGazeTrimTests
/// .panFollowsNegatedYawDeviation`.
///
/// `pitchDeviationDegrees > 0` ⇒ chin up beyond neutral ⇒ (exactly the
/// beacon's own `errorY`/target-negation relationship, with "neutral" in
/// the role "target" plays for the beacon) the correction is DOWN ⇒
/// `pitchRaw = -pitchDeviationDegrees` negative ⇒ LOW register (down ↔ low,
/// metaphor-congruent, same as the beacon's own vertical mapping).
extension RenderState {
  /// One sample's worth of the trim tone. Only ever called from
  /// `mixedSample` while `currentTarget.gazeTrimActive` is `true` (which
  /// implies `currentTarget.inDeadZone == true` — see
  /// `FeedbackRouter.gazeTrimTarget(output:framing:)` — so this and
  /// `positionalSample` are mutually exclusive per sample, never mixed
  /// together).
  func gazeTrimSample(sampleRate: Double) -> (Float, Float) {
    let cfg = config.gazeTrim
    let range = Float(cfg.deviationRangeDegrees)

    let yawRaw = -currentTarget.yawDeviationDegrees
    let pitchRaw = -currentTarget.pitchDeviationDegrees
    let panNormalized: Float = range > 0 ? max(-1, min(1, yawRaw / range)) : 0
    let pitchNormalized: Float = range > 0 ? max(-1, min(1, pitchRaw / range)) : 0

    let freq = AudioSynthesis.exponentialFrequency(
      normalized: pitchRaw, range: range, minHz: cfg.minHz, maxHz: cfg.maxHz)
    gazeTrimPhase = advancedPhase(gazeTrimPhase, freqHz: freq, sampleRate: sampleRate)

    let carrier = gazeTrimCarrier(panNormalized: panNormalized, pitchNormalized: pitchNormalized)
    gazeTrimRampGain = updatedGazeTrimRampGain(sampleRate: sampleRate)
    let amplitude = Float(cfg.gain) * gazeTrimRampGain
    let sample = carrier * amplitude

    let (leftGain, rightGain) = AudioSynthesis.equalPowerPan(panNormalized)
    return (sample * leftGain, sample * rightGain)
  }

  /// **Purity anchor at neutral.** A simpler single ingredient than the
  /// beacon's two-sided brightness/darkness blend (`verticalTimbreMix`),
  /// chosen because trim's purity axis is not directional the way the
  /// beacon's vertical timbre is (brightness above, darkness below) — here
  /// there is nothing to disambiguate beyond "on target or not," and
  /// pan+register already carry the two directional cues. So: crossfade
  /// from the pure fundamental sine toward the SAME accumulator's
  /// `triangleWave` reading (reusing `positionalSample`'s Scheme-C
  /// precedent for a second, still-soft waveform sharing one phase, rather
  /// than introducing a new detune/beat constant that §0 would require its
  /// own `Config` field for) — an exact identity pass at zero deviation
  /// (`impurityMix == 0`), a gentle, still-quiet edge growing toward the
  /// full-scale deviation.
  ///
  /// `impurityMix` is `max(|panNormalized|, |pitchNormalized|)`, not a
  /// combined (e.g. Euclidean) magnitude: "clean/pure when yaw AND pitch
  /// sit at neutral" is an AND condition, so purity should break the
  /// instant EITHER axis drifts, not only when both do together.
  private func gazeTrimCarrier(panNormalized: Float, pitchNormalized: Float) -> Float {
    let pureCarrier = Float(sin(gazeTrimPhase))
    let impurityMix = max(abs(panNormalized), abs(pitchNormalized))
    guard impurityMix > 0 else { return pureCarrier }
    let textured = Float(triangleWave(phase: gazeTrimPhase))
    return pureCarrier + impurityMix * (textured - pureCarrier)
  }

  /// Advances `gazeTrimRampGain` toward `1` over
  /// `Config.AudioGazeTrim.onsetRampMs`, one render sample at a time — a
  /// linear ramp is enough to kill the pop (§3.1: allocation/lock-free,
  /// real-time-safe; a per-sample increment is the cheapest shape that
  /// qualifies). `onsetRampMs <= 0` disables the ramp (instant full gain),
  /// matching `AudioPositional`'s own "0 disables" convention for rate-like
  /// fields elsewhere in this file (e.g. `effectivePitchRange`'s guards).
  private func updatedGazeTrimRampGain(sampleRate: Double) -> Float {
    let rampMs = config.gazeTrim.onsetRampMs
    guard rampMs > 0, sampleRate > 0 else { return 1 }
    let totalSamples = rampMs / 1000 * sampleRate
    guard totalSamples > 0 else { return 1 }
    let step = Float(1 / totalSamples)
    return min(1, gazeTrimRampGain + step)
  }
}
