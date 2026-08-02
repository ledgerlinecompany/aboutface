import Testing

@testable import AboutFaceCore

/// §6.2 vertical-axis timbre differentiation, ROUND 2 (2026-08-02 maintainer
/// audition feedback): "The below indicator is clear, the above indicator is
/// a little less clear. I think maybe something a little more overdriven?
/// Or mix in a saw or something?" `Config.AudioPositional.brightnessStyle`
/// makes the brightness ingredient's synthesis CHARACTER selectable
/// (`.harmonics` — round 1's baseline, covered by
/// `AudioRendererVerticalTimbreTests`, which pins to it explicitly now that
/// the default has moved on; `.overdrive` — the new shipped default;
/// `.saw`) so the maintainer can audition all three and pick by ear (§0/
/// §16). This file covers the two new styles' acceptance cases, plus
/// default-config (now `.overdrive`) purity/axis-isolation coverage.
///
/// Same Goertzel-ratio measurement technique as
/// `AudioRendererVerticalTimbreTests` (see its doc comment for why a RATIO,
/// not an absolute magnitude, is the right measurement — it isolates the
/// ingredient's relative strength from `toneGain`/the distance gate).
struct AudioRendererBrightnessStyleTests {
  private static let sampleRate = 48000.0

  // MARK: - Overdrive: odd harmonics grow with |errorY|

  /// `tanh` waveshaping of a sine adds ONLY odd harmonics (see
  /// `RenderState.overdriveComponent`'s doc comment for why: `tanh` is odd,
  /// and `sin` is half-wave antisymmetric, so their composition is too) —
  /// the 2nd harmonic should stay near the Goertzel spectral-leakage floor
  /// at every intensity, while 3f/5f rise with |errorY|. This is a
  /// genuinely nonlinear waveshaper (unlike round 1's linear additive
  /// blend), so an exact closed-form ratio isn't hand-derivable the way
  /// `AudioRendererVerticalTimbreTests`' `.harmonics` cases were — this
  /// asserts the qualitative shape instead: monotonic growth, and a large
  /// relative jump (not a small one), which is the whole point of this
  /// round ("a little more overdriven" than round 1's subtle blend). Both
  /// `drive` and the crossfade weight scale with intensity together (see
  /// `overdriveComponent`), which compounds the growth faster than the
  /// linear `.harmonics` case.
  @Test("Overdrive: odd-harmonic (3f) energy ratio rises sharply with |errorY|")
  func overdrive_oddHarmonicsGrowWithMagnitude() async throws {
    let small = try await measure(errorX: 0, errorY: -0.1, style: .overdrive)
    let large = try await measure(errorX: 0, errorY: -0.3, style: .overdrive)

    #expect(large.ratio(at: 3) > small.ratio(at: 3))
    #expect(large.ratio(at: 3) > small.ratio(at: 3) * 2)
  }

  @Test("Overdrive: 5th harmonic is also present and growing (confirms odd-harmonic character)")
  func overdrive_fifthHarmonicGrows() async throws {
    let small = try await measure(errorX: 0, errorY: -0.1, style: .overdrive)
    let large = try await measure(errorX: 0, errorY: -0.3, style: .overdrive)

    #expect(large.ratio(at: 5) > small.ratio(at: 5))
  }

  @Test("Overdrive: 2nd harmonic (even) stays far below 3rd (odd) even at strong drive")
  func overdrive_evenHarmonicStaysAbsent() async throws {
    let large = try await measure(errorX: 0, errorY: -0.3, style: .overdrive)
    #expect(large.ratio(at: 2) < large.ratio(at: 3) * 0.3)
  }

  @Test("Overdrive: vertically centered target is an exact pure tone")
  func overdrive_centeredIsPure() async throws {
    let centered = try await measure(errorX: 0, errorY: 0, style: .overdrive)
    let bright = try await measure(errorX: 0, errorY: -0.3, style: .overdrive)
    #expect(centered.ratio(at: 3) < bright.ratio(at: 3) * 0.1)
  }

  // MARK: - Saw: broad harmonic series grows with |errorY|

  /// A sawtooth's harmonic series is broad-spectrum by construction (~1/n
  /// rolloff across EVERY integer harmonic, even and odd alike) — unlike
  /// overdrive's odd-only content, both 2f AND 3f should rise together as
  /// the crossfade toward the saw increases.
  @Test("Saw: both 2f and 3f energy ratios rise with |errorY|")
  func saw_broadHarmonicSeriesGrowsWithMagnitude() async throws {
    let small = try await measure(errorX: 0, errorY: -0.1, style: .saw)
    let large = try await measure(errorX: 0, errorY: -0.3, style: .saw)

    #expect(large.ratio(at: 2) > small.ratio(at: 2))
    #expect(large.ratio(at: 3) > small.ratio(at: 3))
  }

  @Test("Saw: vertically centered target is an exact pure tone")
  func saw_centeredIsPure() async throws {
    let centered = try await measure(errorX: 0, errorY: 0, style: .saw)
    let bright = try await measure(errorX: 0, errorY: -0.3, style: .saw)
    #expect(centered.ratio(at: 2) < bright.ratio(at: 2) * 0.1)
    #expect(centered.ratio(at: 3) < bright.ratio(at: 3) * 0.1)
  }

  /// Coarse aliasing sanity for the polyBLEP saw (task brief: "skip if the
  /// measure is flaky, and say so" — kept because it's cheap and, empirically,
  /// stable: polyBLEP only smooths the couple of samples nearest the
  /// discontinuity, it doesn't promise zero energy above any particular
  /// frequency, so this checks order-of-magnitude headroom near Nyquist
  /// relative to the fundamental, not near-silence).
  @Test("Saw: energy near Nyquist stays a small fraction of the fundamental (aliasing sanity)")
  func saw_nearNyquistEnergyStaysSmall() async throws {
    let result = try await measure(errorX: 0, errorY: -0.3, style: .saw)
    let nearNyquist = AudioRendererTestSupport.goertzelMagnitude(
      result.samples, sampleRate: Self.sampleRate, targetHz: Self.sampleRate * 0.45)
    #expect(nearNyquist < result.fundamental * 0.1)
  }

  // MARK: - New default (.overdrive): purity/axis-isolation still hold

  @Test("Default config (.overdrive): horizontal-only error leaks no vertical ingredient")
  func defaultConfig_axisIsolationHolds() async throws {
    #expect(Config.Audio.defaults.positional.brightnessStyle == .overdrive)
    let horizontalOnly = try await measure(errorX: 0.3, errorY: 0, style: .overdrive)
    let bright = try await measure(errorX: 0, errorY: -0.3, style: .overdrive)
    #expect(horizontalOnly.ratio(at: 3) < bright.ratio(at: 3) * 0.1)
  }

  @Test("Default config (.overdrive): centered stays pure with beaconPolarity flipped")
  func defaultConfig_purityHoldsWithFlippedPolarity() async throws {
    var flipped = Config.Audio.defaults
    flipped.positional.beaconPolarity = false
    let centered = try await measure(errorX: 0, errorY: 0, config: flipped)
    let bright = try await measure(errorX: 0, errorY: 0.3, config: flipped)
    #expect(centered.ratio(at: 3) < bright.ratio(at: 3) * 0.1)
  }

  // MARK: - Measurement helper

  private struct Measurement {
    let samples: [Float]
    let fundamental: Double
    let fundamentalHz: Double
    let sampleRate: Double

    /// Goertzel magnitude at the given integer harmonic of the fundamental,
    /// as a ratio to the fundamental's own magnitude — same rationale as
    /// `AudioRendererVerticalTimbreTests`' `harmonicRatio`/`subOctaveRatio`.
    func ratio(at harmonic: Int) -> Double {
      guard fundamental > 0 else { return 0 }
      let magnitude = AudioRendererTestSupport.goertzelMagnitude(
        samples, sampleRate: sampleRate, targetHz: fundamentalHz * Double(harmonic))
      return magnitude / fundamental
    }
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Renders a steady-state target and returns a `Measurement` to probe
  /// arbitrary harmonics of the fundamental against. `style`, when given,
  /// overrides `config.positional.brightnessStyle` on top of whatever
  /// `config` provides (default `Config.Audio.defaults`) — most call sites
  /// pass `style` explicitly even where it matches the default, so these
  /// tests stay meaningful if the shipped default ever changes again.
  private func measure(
    errorX: Float, errorY: Float, style: Config.BrightnessStyle? = nil,
    config: Config.Audio = .defaults
  )
    async throws -> Measurement
  {
    // swiftlint:enable opening_brace
    var config = config
    if let style {
      config.positional.brightnessStyle = style
    }
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

    return Measurement(
      samples: left, fundamental: fundamental, fundamentalHz: fundamentalHz,
      sampleRate: Self.sampleRate)
  }
}
