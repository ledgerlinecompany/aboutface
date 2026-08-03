import Testing

@testable import AboutFaceCore

/// Coarse, robust acceptance properties for `AudioRenderer`'s continuous
/// positional sonification (§6.2, §13 Phase 3 requirement 6): stereo
/// balance tracks `errorX`, dominant frequency tracks `errorY`, distance
/// maps to pulse rate, output mode compensation (§6.2), and Scheme C's
/// sequential axis behavior. Exact sign derivations for the shipped beacon
/// polarity live in `AudioRendererBeaconPolarityTests`; these tests use
/// relative/comparative assertions instead.
struct AudioRendererPositionalTests {

  /// `Config.Audio.defaults` with Scheme B pinned OFF. Scheme B now
  /// defaults ON (2026-08-02, §16.2); many of this file's error magnitudes
  /// (small `errorX`/`errorY`, near-zero `distanceError`) sit inside its
  /// 0.8×errorRange engagement envelope, and its click-train transients
  /// would otherwise bleed into these stereo-balance/dominant-frequency/
  /// envelope-dip measurements, which are meant to isolate Scheme A's
  /// positional mapping alone.
  private static var pinnedConfig: Config.Audio {
    var config = Config.Audio.defaults
    config.scheme.schemeBEnabled = false
    return config
  }

  // MARK: - Stereo balance responds to errorX sign

  @Test("Stereo balance flips between opposite-sign errorX")
  func stereoBalanceRespondsToErrorXSign() async throws {
    let rightRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0.25, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (rLeft, rRight) = try await AudioRendererTestSupport.renderFrames(
      rightRenderer, total: 8192)

    let leftRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: -0.25, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (lLeft, lRight) = try await AudioRendererTestSupport.renderFrames(leftRenderer, total: 8192)

    let rightCaseBalance =
      AudioRendererTestSupport.rms(rRight) - AudioRendererTestSupport.rms(rLeft)
    let leftCaseBalance = AudioRendererTestSupport.rms(lRight) - AudioRendererTestSupport.rms(lLeft)

    // Whichever direction +errorX pans toward, -errorX must pan the other
    // way — the balance metric (right RMS minus left RMS) must flip sign.
    #expect(rightCaseBalance * leftCaseBalance < 0)
  }

  @Test("Centered errorX (0) produces roughly balanced stereo output")
  func centeredErrorXProducesBalancedOutput() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.2, distanceError: 0, inDeadZone: false))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    let leftRMS = AudioRendererTestSupport.rms(left)
    let rightRMS = AudioRendererTestSupport.rms(right)

    #expect(abs(leftRMS - rightRMS) < 0.05 * max(leftRMS, rightRMS))
  }

  // MARK: - Dominant frequency responds to errorY sign

  @Test("Dominant frequency differs between opposite-sign errorY")
  func dominantFrequencyRespondsToErrorYSign() async throws {
    let aboveRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false))
    }
    let (aboveLeft, _) = try await AudioRendererTestSupport.renderFrames(
      aboveRenderer, total: 16384)
    let aboveFreq = AudioRendererTestSupport.dominantFrequency(
      aboveLeft, sampleRate: 48000, minHz: 220, maxHz: 880)

    let belowRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: -0.3, distanceError: 0, inDeadZone: false))
    }
    let (belowLeft, _) = try await AudioRendererTestSupport.renderFrames(
      belowRenderer, total: 16384)
    let belowFreq = AudioRendererTestSupport.dominantFrequency(
      belowLeft, sampleRate: 48000, minHz: 220, maxHz: 880)

    #expect(aboveFreq != belowFreq)
  }

  // MARK: - Distance maps to pulse rate (never volume — see Config.AudioDistance)

  @Test("Larger |distanceError| produces a faster amplitude gate (more envelope dips per second)")
  func distanceErrorMagnitudeIncreasesPulseRate() async throws {
    // "Near" is a small NONZERO magnitude (0.03), not exactly 0: since the
    // §6.2 round-4 purity anchor (`RenderState.distanceGate`) makes the
    // gate depth itself scale to 0 at exactly zero error (genuinely
    // steady, no dips at all), comparing against exactly-0 here would test
    // "modulation present vs. absent" rather than the rate actually
    // tracking magnitude, which is this test's point —
    // `AudioRendererDistanceDirectionTests.zeroErrorIsSteady` covers the
    // exactly-0 anchor case directly.
    let nearRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.03, inDeadZone: false))
    }
    let (nearLeft, _) = try await AudioRendererTestSupport.renderFrames(nearRenderer, total: 48000)
    let nearDips = AudioRendererTestSupport.envelopeDipCount(nearLeft, blockSize: 480)

    let farRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.3, inDeadZone: false))
    }
    let (farLeft, _) = try await AudioRendererTestSupport.renderFrames(farRenderer, total: 48000)
    let farDips = AudioRendererTestSupport.envelopeDipCount(farLeft, blockSize: 480)

    // Config.Audio.defaults.distance: pulseRateMinHz = 1, pulseRateMaxHz = 8
    // over 1 second of audio — expect roughly 1 dip vs. roughly 8, so a
    // coarse ">" comparison is a robust, generously-margined assertion.
    #expect(farDips > nearDips)
  }

  // MARK: - Output mode compensation (§6.2)

  @Test("Speakers output mode narrows pan magnitude relative to headphones")
  func speakersModeNarrowsPan() async throws {
    var speakersConfig = Self.pinnedConfig
    speakersConfig.outputMode = .speakers
    let target = SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false)

    let headphonesRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(target)
    }
    let (hLeft, hRight) = try await AudioRendererTestSupport.renderFrames(
      headphonesRenderer, total: 8192)
    let headphonesBalance = abs(
      AudioRendererTestSupport.rms(hLeft) - AudioRendererTestSupport.rms(hRight))

    let speakersRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: speakersConfig
    ) { renderer in
      await renderer.update(target)
    }
    let (sLeft, sRight) = try await AudioRendererTestSupport.renderFrames(
      speakersRenderer, total: 8192)
    let speakersBalance = abs(
      AudioRendererTestSupport.rms(sLeft) - AudioRendererTestSupport.rms(sRight))

    #expect(speakersBalance < headphonesBalance)
  }

  @Test("Speakers output mode widens the pitch range relative to headphones")
  func speakersModeWidensPitchRange() async throws {
    var speakersConfig = Self.pinnedConfig
    speakersConfig.outputMode = .speakers
    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)
    let reference = Config.Audio.defaults.positional.referenceToneHz

    let headphonesRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: Self.pinnedConfig
    ) { renderer in
      await renderer.update(target)
    }
    let (hLeft, _) = try await AudioRendererTestSupport.renderFrames(
      headphonesRenderer, total: 16384)
    let headphonesFreq = AudioRendererTestSupport.dominantFrequency(
      hLeft, sampleRate: 48000, minHz: 100, maxHz: 1200)

    let speakersRenderer = try await AudioRendererTestSupport.makeRenderer(
      config: speakersConfig
    ) { renderer in
      await renderer.update(target)
    }
    let (sLeft, _) = try await AudioRendererTestSupport.renderFrames(speakersRenderer, total: 16384)
    let speakersFreq = AudioRendererTestSupport.dominantFrequency(
      sLeft, sampleRate: 48000, minHz: 100, maxHz: 1200)

    // errorY = +0.3 (beacon default) is a below-reference case; the
    // speakers-mode expanded range should push it further from the
    // reference tone than the headphones-mode range does.
    #expect(abs(speakersFreq - reference) > abs(headphonesFreq - reference))
  }

  // MARK: - Scheme C (sequential axis, mono fallback)

  @Test("Scheme C: large horizontal error (vertical solved) tracks errorX, not errorY")
  func sequentialScheme_unsolvedHorizontal_tracksErrorX() async throws {
    // No Scheme B pin needed here (unlike this file's other configs):
    // `schemeBSampleIfActive` requires `positional == .panPitch`, so
    // Scheme C is architecturally immune to B regardless of `schemeBEnabled`.
    var config = Config.Audio.defaults
    config.scheme.positional = .sequential
    // errorX far outside sequentialAxisThreshold (0.15 * 0.35 ≈ 0.0525);
    // errorY at zero, so if the renderer were (incorrectly) tracking
    // vertical here the dominant frequency would sit at the reference tone.
    let target = SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(target)
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
    let freq = AudioRendererTestSupport.dominantFrequency(
      left, sampleRate: 48000, minHz: 220, maxHz: 880)

    #expect(abs(freq - config.positional.referenceToneHz) > 50)
  }

  @Test("Scheme C: solved horizontal (errorX ≈ 0) advances to tracking errorY")
  func sequentialScheme_solvedHorizontal_tracksErrorY() async throws {
    // No Scheme B pin needed here (unlike this file's other configs):
    // `schemeBSampleIfActive` requires `positional == .panPitch`, so
    // Scheme C is architecturally immune to B regardless of `schemeBEnabled`.
    var config = Config.Audio.defaults
    config.scheme.positional = .sequential
    // errorX inside the threshold ("solved"); errorY large and positive.
    // Beacon polarity negates errorY, so "above target" (+0.3) should map
    // to a low frequency, same derivation as the pan/pitch beacon tests.
    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(target)
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
    let freq = AudioRendererTestSupport.dominantFrequency(
      left, sampleRate: 48000, minHz: 220, maxHz: 880)

    #expect(freq < 400)
  }
}
