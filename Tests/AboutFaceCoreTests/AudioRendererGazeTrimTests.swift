import Testing

@testable import AboutFaceCore

/// Tuning round 5 (maintainer-designed audition prototype — `Config
/// .AudioGazeTrim`, default OFF). §6.1-adjacent hard requirement: trim must
/// be different IN KIND from the beacon, never mistakable for it. See
/// `RenderState+GazeTrim.swift`'s type-level doc comment for the sign
/// derivations these tests assert against.
struct AudioRendererGazeTrimTests {
  private static let sampleRate = 48000.0

  /// `Config.Audio.defaults` with the onset ramp disabled, for tests that
  /// want a clean steady-state read from the first sample rather than
  /// waiting out the (default 300ms) onset ramp. The ramp itself is
  /// exercised on its own terms by `onsetRamp_noDiscontinuityAtActivation`
  /// below.
  private static var steadyStateConfig: Config.Audio {
    var config = Config.Audio.defaults
    config.gazeTrim.onsetRampMs = 0
    return config
  }

  private func trimTarget(
    yawDeviationDegrees: Float = 0, pitchDeviationDegrees: Float = 0
  ) -> SonificationTarget {
    SonificationTarget(
      errorX: 0, errorY: 0, distanceError: 0, inDeadZone: true, gazeTrimActive: true,
      yawDeviationDegrees: yawDeviationDegrees, pitchDeviationDegrees: pitchDeviationDegrees)
  }

  // MARK: - Register disjoint from the beacon

  @Test("trim register (default 1600-2400Hz) is disjoint from the beacon register (220-880Hz)")
  func trimRegister_disjointFromBeaconRegister() async throws {
    let beaconRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: -0.3, distanceError: 0, inDeadZone: false))
    }
    let (beaconLeft, _) = try await AudioRendererTestSupport.renderFrames(
      beaconRenderer, total: 16384)
    let beaconDominant = AudioRendererTestSupport.dominantFrequency(
      beaconLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)

    let trimRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget(pitchDeviationDegrees: -20))
    }
    let (trimLeft, _) = try await AudioRendererTestSupport.renderFrames(trimRenderer, total: 16384)
    let trimDominant = AudioRendererTestSupport.dominantFrequency(
      trimLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)

    #expect(beaconDominant <= 880)
    #expect(trimDominant >= 1600)
  }

  // MARK: - Quieter than the beacon at equal (default) config

  @Test("trim is quieter than the beacon at default config (RMS)")
  func trimIsQuieterThanBeaconAtDefaults() async throws {
    let beaconRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (beaconLeft, _) = try await AudioRendererTestSupport.renderFrames(
      beaconRenderer, total: 8192)

    let trimRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget())
    }
    let (trimLeft, _) = try await AudioRendererTestSupport.renderFrames(trimRenderer, total: 8192)

    #expect(AudioRendererTestSupport.rms(trimLeft) < AudioRendererTestSupport.rms(beaconLeft))
  }

  // MARK: - Pan sign matches -yawDeviation (hand-derived)

  /// Hand-derived (`Config.AudioGazeTrim.defaults`: `deviationRangeDegrees
  /// = 20`): `yawDeviationDegrees = +10` ("turned right of neutral") →
  /// `panRaw = -10` → `panNormalized = clamp(-10/20, -1, 1) = -0.5` →
  /// LEFT-dominant (turn left to correct — "sound from the left," per the
  /// task brief's own hand-derivation).
  @Test("yawDeviation = +10 (turned right of neutral) produces LEFT-dominant tone")
  func positiveYawDeviation_producesLeftDominantTone() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget(yawDeviationDegrees: 10))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    #expect(AudioRendererTestSupport.rms(left) > AudioRendererTestSupport.rms(right))
  }

  /// Symmetric case: `yawDeviationDegrees = -10` ("turned left of
  /// neutral") → `panRaw = +10` → RIGHT-dominant.
  @Test("yawDeviation = -10 (turned left of neutral) produces RIGHT-dominant tone")
  func negativeYawDeviation_producesRightDominantTone() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget(yawDeviationDegrees: -10))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    #expect(AudioRendererTestSupport.rms(right) > AudioRendererTestSupport.rms(left))
  }

  // MARK: - Purity at neutral

  /// At zero deviation on both axes, `gazeTrimCarrier` is an exact
  /// identity pass to the pure fundamental sine (`impurityMix == 0`
  /// short-circuits before touching `triangleWave`) — so harmonic energy
  /// (measured the same way `AudioRendererVerticalTimbreTests` measures
  /// the beacon's own purity-at-center) should be far lower at neutral
  /// than at full-scale deviation, where the triangle-wave ingredient is
  /// fully mixed in.
  @Test("neutral (0,0) is a purer tone than full-scale deviation")
  func neutralDeviation_isPurerThanFullScale() async throws {
    let neutralRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget())
    }
    let (neutralLeft, _) = try await AudioRendererTestSupport.renderFrames(
      neutralRenderer, total: 16384)

    let fullScaleRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget(yawDeviationDegrees: 20, pitchDeviationDegrees: 20))
    }
    let (fullScaleLeft, _) = try await AudioRendererTestSupport.renderFrames(
      fullScaleRenderer, total: 16384)

    let cfg = Self.steadyStateConfig.gazeTrim
    // Center frequency (both deviations 0): the geometric mean of
    // minHz/maxHz, same as `AudioSynthesis.exponentialFrequency`'s own
    // `t == 0.5` case.
    let centerHz = (cfg.minHz * cfg.maxHz).squareRoot()
    let neutralThirdHarmonicRatio = harmonicRatio(
      neutralLeft, fundamentalHz: centerHz, harmonic: 3)

    // Full-scale case: pitchDeviation = 20 -> pitchRaw = -20 -> normalized
    // = -1 -> minHz.
    let fullScaleThirdHarmonicRatio = harmonicRatio(
      fullScaleLeft, fundamentalHz: cfg.minHz, harmonic: 3)

    #expect(neutralThirdHarmonicRatio < fullScaleThirdHarmonicRatio * 0.3)
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  private func harmonicRatio(_ samples: [Float], fundamentalHz: Double, harmonic: Double)
    -> Double
  {
    // swiftlint:enable opening_brace
    let fundamental = AudioRendererTestSupport.goertzelMagnitude(
      samples, sampleRate: Self.sampleRate, targetHz: fundamentalHz)
    let overtone = AudioRendererTestSupport.goertzelMagnitude(
      samples, sampleRate: Self.sampleRate, targetHz: fundamentalHz * harmonic)
    guard fundamental > 0 else { return 0 }
    return overtone / fundamental
  }

  // MARK: - No discontinuity at activation (onset ramp)

  /// With the default `onsetRampMs = 300`, the first few milliseconds of
  /// trim audio must be much quieter than a window taken after the ramp
  /// has completed — "slow onset... no pop when entering the zone."
  @Test("onset ramp: amplitude climbs gradually, no instant full-gain pop")
  func onsetRamp_noDiscontinuityAtActivation() async throws {
    // Default config: onsetRampMs = 300ms == 14400 samples @ 48kHz.
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(trimTarget(yawDeviationDegrees: 15))
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 24000)

    // First 5ms (240 samples) vs. a 5ms window comfortably after the
    // 300ms ramp completes (samples 20000..20240, ~417ms in).
    let earlyWindow = Array(left[0..<240])
    let lateWindow = Array(left[20000..<20240])

    let earlyRMS = AudioRendererTestSupport.rms(earlyWindow)
    let lateRMS = AudioRendererTestSupport.rms(lateWindow)

    #expect(earlyRMS < lateRMS * 0.1)
  }

  @Test("onset ramp disabled (onsetRampMs = 0) reaches full gain immediately")
  func onsetRampDisabled_reachesFullGainImmediately() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.steadyStateConfig
    ) { renderer in
      await renderer.update(trimTarget(yawDeviationDegrees: 15))
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 4096)

    let earlyWindow = Array(left[0..<240])
    let lateWindow = Array(left[2000..<2240])
    let earlyRMS = AudioRendererTestSupport.rms(earlyWindow)
    let lateRMS = AudioRendererTestSupport.rms(lateWindow)

    // No meaningful growth once the ramp is disabled — both windows should
    // already be at full, comparable amplitude.
    #expect(earlyRMS > lateRMS * 0.7)
  }
}
