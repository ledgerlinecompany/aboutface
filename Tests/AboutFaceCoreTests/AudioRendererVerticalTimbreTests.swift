import Testing

@testable import AboutFaceCore

/// §6.2 vertical-axis timbre differentiation (2026-08-02 maintainer tuning
/// directive, first audition session): "it's obvious when sounds are
/// off-center, but I'm not sure if it's obvious what pitch we're aiming to
/// center on vertically." Center stays a PURE tone (no added harmonics or
/// sub-octave); each vertical direction blends in a distinct ingredient
/// that grows with `|errorY|` — brightness (added upper harmonics) when the
/// TARGET is above the subject, darkness (a sub-octave) when it's below.
/// See `RenderState.verticalTimbreMix`'s doc comment for the full
/// hand-derived sign chain (mirrored here for the test cases) and
/// `Config.AudioPositional.maxBrightnessMix`/`maxDarknessMix`.
///
/// Measurements use a RATIO of Goertzel magnitude at the harmonic/
/// sub-octave frequency to magnitude at the fundamental, rather than an
/// absolute magnitude — this isolates the timbral ingredient's relative
/// strength from the carrier's overall amplitude (which `toneGain` and the
/// distance gate also affect, and which is irrelevant to what's being
/// tested here), matching `AudioRendererPositionalTests`' documented
/// preference for coarse, robust, relative measurements over exact ones.
struct AudioRendererVerticalTimbreTests {
  private static let sampleRate = 48000.0

  // MARK: - Above target (brightness)

  /// Hand-derived (`Config.Audio.defaults.positional`: `errorRange = 0.35`,
  /// `beaconPolarity = true`, `maxBrightnessMix = 0.5`): `errorY = -0.1`
  /// ("subject below target" ⇒ target ABOVE) ⇒ `signMultiplier = -1` ⇒
  /// `pitchRaw = +0.1` ⇒ `normalized = 0.1/0.35 ≈ 0.286` ⇒
  /// `brightnessMix = 0.5 · 0.286 ≈ 0.143`; `errorY = -0.3` ⇒ `pitchRaw =
  /// +0.3` ⇒ `normalized ≈ 0.857` ⇒ `brightnessMix ≈ 0.429`. The 2nd
  /// harmonic's amplitude coefficient is `0.6 · brightnessMix`, so the
  /// large case's 2f/fundamental ratio (~0.257) should come out roughly 3x
  /// the small case's (~0.086) — asserted with a generous margin below.
  @Test("Above-target vertical error blends in brightness (2f) growing with |errorY|")
  func aboveTarget_brightnessGrowsWithMagnitude() async throws {
    let small = try await measure(errorX: 0, errorY: -0.1)
    let large = try await measure(errorX: 0, errorY: -0.3)

    #expect(large.harmonicRatio > small.harmonicRatio)
    #expect(large.harmonicRatio > small.harmonicRatio * 1.5)
  }

  @Test("Above-target vertical error leaves the sub-octave (darkness) ~absent")
  func aboveTarget_subOctaveStaysAbsent() async throws {
    let result = try await measure(errorX: 0, errorY: -0.3)
    #expect(result.subOctaveRatio < result.harmonicRatio * 0.25)
  }

  // MARK: - Below target (darkness)

  /// Hand-derived: `errorY = +0.1` ("subject above target" ⇒ target BELOW)
  /// ⇒ `pitchRaw = -0.1` ⇒ `normalized ≈ -0.286` ⇒ `darknessMix ≈ 0.143`;
  /// `errorY = +0.3` ⇒ `pitchRaw = -0.3` ⇒ `normalized ≈ -0.857` ⇒
  /// `darknessMix ≈ 0.429`. The sub-octave has coefficient `darknessMix`
  /// directly (no 0.6/0.4 split, unlike the two-harmonic brightness blend),
  /// so its ratio scales ~linearly with `|errorY|` too.
  @Test("Below-target vertical error blends in darkness (f/2) growing with |errorY|")
  func belowTarget_darknessGrowsWithMagnitude() async throws {
    let small = try await measure(errorX: 0, errorY: 0.1)
    let large = try await measure(errorX: 0, errorY: 0.3)

    #expect(large.subOctaveRatio > small.subOctaveRatio)
    #expect(large.subOctaveRatio > small.subOctaveRatio * 1.5)
  }

  @Test("Below-target vertical error leaves the harmonics (brightness) ~absent")
  func belowTarget_harmonicsStayAbsent() async throws {
    let result = try await measure(errorX: 0, errorY: 0.3)
    #expect(result.harmonicRatio < result.subOctaveRatio * 0.25)
  }

  // MARK: - Centered vertically (purity)

  /// `errorY = 0` ⇒ `pitchRaw = 0` ⇒ `normalized = 0` ⇒ both
  /// `brightnessMix` and `darknessMix` are exactly 0 ⇒ the carrier is the
  /// pure fundamental sine only — the whole point of the design (§6.2:
  /// "purity-at-center gives the target an intrinsic sonic identity").
  @Test("Vertically centered target is a pure tone: no brightness or darkness ingredient")
  func centeredVertically_isPure() async throws {
    let centered = try await measure(errorX: 0, errorY: 0)
    let brightCase = try await measure(errorX: 0, errorY: -0.3)
    let darkCase = try await measure(errorX: 0, errorY: 0.3)

    // Any residual at center is Goertzel spectral leakage from the strong
    // fundamental, not a real ingredient — compare against the unambiguous
    // large-error cases rather than an absolute threshold.
    #expect(centered.harmonicRatio < brightCase.harmonicRatio * 0.3)
    #expect(centered.subOctaveRatio < darkCase.subOctaveRatio * 0.3)
  }

  // MARK: - Axis isolation

  /// `errorX = 0.3, errorY = 0` (Scheme A: horizontal and vertical are
  /// simultaneous, not sequential) ⇒ `pitchRaw` still derives from
  /// `errorY` alone ⇒ 0 regardless of how far off-center the pan is ⇒ no
  /// vertical ingredient leaks in from horizontal error.
  @Test("Horizontal-only error produces no vertical timbre ingredient (axis isolation)")
  func horizontalOnlyError_noVerticalIngredient() async throws {
    let horizontalOnly = try await measure(errorX: 0.3, errorY: 0)
    let brightCase = try await measure(errorX: 0, errorY: -0.3)
    let darkCase = try await measure(errorX: 0, errorY: 0.3)

    #expect(horizontalOnly.harmonicRatio < brightCase.harmonicRatio * 0.3)
    #expect(horizontalOnly.subOctaveRatio < darkCase.subOctaveRatio * 0.3)
  }

  // MARK: - Polarity flip

  /// `beaconPolarity = false` restores the non-negated "error-marker"
  /// convention (`signMultiplier = +1`): `errorY = -0.3` now gives
  /// `pitchRaw = -0.3` (negative — the MIRROR of the default-polarity
  /// derivation above, where the same `errorY` gives `pitchRaw = +0.3`).
  /// The timbre ingredient is keyed on the same post-polarity `pitchRaw`
  /// the frequency mapping uses, so it must flip too: this `errorY` now
  /// produces DARKNESS, not brightness — proving the ingredient can never
  /// disagree with the pitch direction even when the flag flips.
  @Test("beaconPolarity = false flips which side gets brightness vs. darkness")
  func polarityFlip_ingredientFollowsPitchMapping() async throws {
    var flipped = Config.Audio.defaults
    flipped.positional.beaconPolarity = false

    // Default polarity: this errorY is the "above target" (brightness) case.
    let defaultCase = try await measure(errorX: 0, errorY: -0.3)
    // Flipped polarity, same errorY: now the "below target" (darkness) case.
    let flippedCase = try await measure(errorX: 0, errorY: -0.3, config: flipped)

    #expect(defaultCase.harmonicRatio > defaultCase.subOctaveRatio)
    #expect(flippedCase.subOctaveRatio > flippedCase.harmonicRatio)
  }

  // MARK: - Measurement helper

  private struct Ratios {
    let harmonicRatio: Double
    let subOctaveRatio: Double
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Renders a steady-state target and returns the 2f/fundamental
  /// ("brightness") and (f/2)/fundamental ("darkness") Goertzel magnitude
  /// ratios. `fundamentalHz` is computed independently via the same
  /// `AudioSynthesis.exponentialFrequency` call the renderer itself makes
  /// (rather than detected), so the harmonic/sub-octave probe frequencies
  /// are exact, not estimated.
  private func measure(errorX: Float, errorY: Float, config: Config.Audio = .defaults)
    async throws -> Ratios
  {
    // swiftlint:enable opening_brace
    let target = SonificationTarget(
      errorX: errorX, errorY: errorY, distanceError: 0, inDeadZone: false)
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
