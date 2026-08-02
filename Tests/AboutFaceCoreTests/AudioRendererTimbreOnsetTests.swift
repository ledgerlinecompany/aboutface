import Testing

@testable import AboutFaceCore

/// §6.2 timbre ONSET curve (2026-08-02 first live convergence-trial
/// finding): "huge jump in perceived pitch from too low to too high" when
/// crossing vertical center quickly, because the brightness/darkness
/// ingredient swap used to be LINEAR in `|normalized error|` — a fast
/// crossing still carried an audible amount of one ingredient right up to
/// the flip. `Config.AudioPositional.timbreOnsetExponent` reshapes
/// `RenderState.verticalTimbreMix`'s mix from `maxMix · |normalized|` to
/// `maxMix · |normalized|^exponent` — see that Config field's doc comment
/// and `verticalTimbreMix`'s own for the full reasoning.
///
/// Companion to `AudioRendererVerticalTimbreTests`, which pins
/// `timbreOnsetExponent` to the OLD linear `1.0` so its hand-derived
/// arithmetic stays exact regardless of what `Config.Audio.defaults`' own
/// default becomes; this file covers the onset curve itself. Pinned to
/// `.harmonics` for the same reason that file is — an additive blend is
/// hand-derivable, unlike `.overdrive`'s genuinely nonlinear waveshaping.
struct AudioRendererTimbreOnsetTests {
  private static let sampleRate = 48000.0
  private static let errorRange = Config.Audio.defaults.positional.errorRange

  /// `Config.Audio.defaults` with `brightnessStyle` pinned to `.harmonics`
  /// and `timbreOnsetExponent` set to the given value.
  private static func config(exponent: Double) -> Config.Audio {
    var config = Config.Audio.defaults
    config.positional.brightnessStyle = .harmonics
    config.positional.timbreOnsetExponent = exponent
    // Pinned to 0 (2026-08-02 action round, item 1): the shipped default
    // moved to `0.03`, and `halfRangeErrorY`/this file's other `errorY`
    // values aren't all exact multiples of it — quantization would shift
    // the hand-derived `|normalized| == 0.5` exactness these tests rely
    // on. Pin rather than re-derive.
    config.positional.errorQuantizationStep = 0
    return config
  }

  /// `errorY` such that (post-beacon-polarity: `pitchRaw = -errorY`, since
  /// `beaconPolarity` defaults `true`) `|normalized| == 0.5` exactly:
  /// `pitchRaw = 0.5 · errorRange` ⇒ `errorY = -0.5 · errorRange`. This is
  /// the "above target" (brightness) sign; its negation is the "below
  /// target" (darkness) sign at the same magnitude.
  private static var halfRangeErrorY: Float { -0.5 * Float(errorRange) }

  // MARK: - Superlinear onset: measurably below the linear case at half range

  /// Hand-derived (§6.2 extension): `|normalized| == 0.5`. Linear
  /// (`exponent == 1.0`): `magnitude = 0.5` ⇒ `brightnessMix = 0.5 · 0.5 =
  /// 0.25` (half of `maxBrightnessMix`). Superlinear (`exponent == 2.0`,
  /// the shipped default): `magnitude = 0.5² = 0.25` ⇒ `brightnessMix =
  /// 0.5 · 0.25 = 0.125` (a quarter of `maxBrightnessMix`) — exactly half
  /// the linear ingredient energy. `.harmonics`' 2nd-harmonic amplitude is
  /// `0.6 · brightnessMix` with no other nonlinearity in the way (the
  /// fundamental's own coefficient is untouched by `intensity`), so the
  /// measured Goertzel ratio tracks that 0.125/0.25 = 0.5 factor directly.
  @Test("Exponent 2.0 halves the brightness ingredient's energy vs. linear at half range")
  func exponentTwo_halvesEnergyAtHalfRange() async throws {
    let linear = try await measure(errorY: Self.halfRangeErrorY, exponent: 1.0)
    let superlinear = try await measure(errorY: Self.halfRangeErrorY, exponent: 2.0)

    #expect(superlinear.harmonicRatio < linear.harmonicRatio)
    // Generous margin around the hand-derived 0.5x factor rather than an
    // exact equality, matching this suite's existing Goertzel-ratio
    // measurement precedent (spectral leakage, buffer-length effects).
    #expect(superlinear.harmonicRatio < linear.harmonicRatio * 0.65)
    #expect(superlinear.harmonicRatio > linear.harmonicRatio * 0.35)
  }

  /// Same shape, darkness (sub-octave) side — `verticalTimbreMix` applies
  /// the identical `pow` curve to `darknessMix` (§6.2 extension: "applies
  /// to BOTH brightness and darkness mixes"), so the crossing stays
  /// symmetric.
  @Test("Exponent 2.0 halves the darkness ingredient's energy vs. linear at half range")
  func exponentTwo_halvesDarknessEnergyAtHalfRange() async throws {
    let errorY = -Self.halfRangeErrorY
    let linear = try await measure(errorY: errorY, exponent: 1.0)
    let superlinear = try await measure(errorY: errorY, exponent: 2.0)

    #expect(superlinear.subOctaveRatio < linear.subOctaveRatio)
    #expect(superlinear.subOctaveRatio < linear.subOctaveRatio * 0.65)
    #expect(superlinear.subOctaveRatio > linear.subOctaveRatio * 0.35)
  }

  // MARK: - Exponent 1.0 reproduces the old linear behavior

  /// Matches `AudioRendererVerticalTimbreTests
  /// .aboveTarget_brightnessGrowsWithMagnitude`'s own hand-derivation at the
  /// same two error values, confirming `exponent == 1.0` is bit-for-bit the
  /// pre-2026-08-02 mapping, not merely "close."
  @Test("Exponent 1.0 reproduces the pre-existing linear onset behavior")
  func exponentOne_matchesLegacyLinearBehavior() async throws {
    let small = try await measure(errorY: -0.1, exponent: 1.0)
    let large = try await measure(errorY: -0.3, exponent: 1.0)

    #expect(large.harmonicRatio > small.harmonicRatio)
    #expect(large.harmonicRatio > small.harmonicRatio * 1.5)
  }

  // MARK: - Purity at center is unchanged by the exponent

  /// `0^exponent == 0` for any exponent — center stays an exact pure tone
  /// regardless of the onset curve's shape (the whole point of keeping the
  /// curve applied to `|normalized|`, not added as an offset).
  @Test("Vertically centered target stays pure at every onset exponent")
  func centeredStaysPureAtEveryExponent() async throws {
    for exponent in [1.0, 2.0, 3.5] {
      let centered = try await measure(errorY: 0, exponent: exponent)
      let bright = try await measure(errorY: -0.3, exponent: exponent)
      #expect(centered.harmonicRatio < bright.harmonicRatio * 0.3)
    }
  }

  // MARK: - Full-scale character at the outer edge is unchanged

  /// `1^exponent == 1` for any exponent — at the outer edge of `errorRange`
  /// (`|normalized| == 1`, clamped beyond it), every exponent converges to
  /// the same full-strength ingredient.
  @Test("Full-scale (outer-edge) brightness intensity is the same for every exponent")
  func outerEdgeIntensityMatchesAcrossExponents() async throws {
    let errorY = -Float(Self.errorRange)  // |normalized| == 1
    let linear = try await measure(errorY: errorY, exponent: 1.0)
    let superlinear = try await measure(errorY: errorY, exponent: 2.0)

    // Both should land at the same full-strength `0.6 * maxBrightnessMix`
    // 2nd-harmonic amplitude — compare with a tight relative tolerance
    // rather than exact equality, consistent with this suite's Goertzel
    // measurement precedent.
    #expect(abs(superlinear.harmonicRatio - linear.harmonicRatio) < linear.harmonicRatio * 0.05)
  }

  // MARK: - Measurement helper (mirrors AudioRendererVerticalTimbreTests' own)

  private struct Ratios {
    let harmonicRatio: Double
    let subOctaveRatio: Double
  }

  private func measure(errorY: Float, exponent: Double) async throws -> Ratios {
    let config = Self.config(exponent: exponent)
    let target = SonificationTarget(
      errorX: 0, errorY: errorY, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(target)
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)

    let signMultiplier: Float = config.positional.beaconPolarity ? -1 : 1
    let pitchRaw = signMultiplier * errorY
    let fundamentalHz = AudioSynthesis.exponentialFrequency(
      normalized: pitchRaw, range: Float(config.positional.errorRange),
      minHz: config.positional.minToneHz, maxHz: config.positional.maxToneHz)

    let fundamental = AudioRendererTestSupport.goertzelMagnitude(
      left, sampleRate: Self.sampleRate, targetHz: fundamentalHz)
    let harmonic = AudioRendererTestSupport.goertzelMagnitude(
      left, sampleRate: Self.sampleRate, targetHz: fundamentalHz * 2)
    let subOctave = AudioRendererTestSupport.goertzelMagnitude(
      left, sampleRate: Self.sampleRate, targetHz: fundamentalHz / 2)

    guard fundamental > 0 else { return Ratios(harmonicRatio: 0, subOctaveRatio: 0) }
    return Ratios(harmonicRatio: harmonic / fundamental, subOctaveRatio: subOctave / fundamental)
  }
}
