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

  // MARK: - Stereo balance responds to errorX sign

  @Test("Stereo balance flips between opposite-sign errorX")
  func stereoBalanceRespondsToErrorXSign() async throws {
    let rightRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0.25, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (rLeft, rRight) = try await AudioRendererTestSupport.renderFrames(
      rightRenderer, total: 8192)

    let leftRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
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
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
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
    let aboveRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false))
    }
    let (aboveLeft, _) = try await AudioRendererTestSupport.renderFrames(
      aboveRenderer, total: 16384)
    let aboveFreq = AudioRendererTestSupport.dominantFrequency(
      aboveLeft, sampleRate: 48000, minHz: 220, maxHz: 880)

    let belowRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
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
    let nearRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (nearLeft, _) = try await AudioRendererTestSupport.renderFrames(nearRenderer, total: 48000)
    let nearDips = envelopeDipCount(nearLeft, blockSize: 480)

    let farRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.3, inDeadZone: false))
    }
    let (farLeft, _) = try await AudioRendererTestSupport.renderFrames(farRenderer, total: 48000)
    let farDips = envelopeDipCount(farLeft, blockSize: 480)

    // Config.Audio.defaults.distance: pulseRateMinHz = 1, pulseRateMaxHz = 8
    // over 1 second of audio — expect roughly 1 dip vs. roughly 8, so a
    // coarse ">" comparison is a robust, generously-margined assertion.
    #expect(farDips > nearDips)
  }

  // MARK: - Output mode compensation (§6.2)

  @Test("Speakers output mode narrows pan magnitude relative to headphones")
  func speakersModeNarrowsPan() async throws {
    var speakersConfig = Config.Audio.defaults
    speakersConfig.outputMode = .speakers
    let target = SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false)

    let headphonesRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }
    let (hLeft, hRight) = try await AudioRendererTestSupport.renderFrames(
      headphonesRenderer, total: 8192)
    let headphonesBalance = abs(
      AudioRendererTestSupport.rms(hLeft) - AudioRendererTestSupport.rms(hRight))

    // swift-format wraps the closure's `renderer in` onto its own line once
    // the opening-brace line is too long; swiftlint's closure_parameter_position
    // rule wants it on the same line as `{`. Format wins (see
    // ConfigStore.swift for the same kind of workaround, a different rule).
    // swiftlint:disable closure_parameter_position
    let speakersRenderer = try await AudioRendererTestSupport.makeRenderer(config: speakersConfig) {
      renderer in
      // swiftlint:enable closure_parameter_position
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
    var speakersConfig = Config.Audio.defaults
    speakersConfig.outputMode = .speakers
    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)
    let reference = Config.Audio.defaults.positional.referenceToneHz

    let headphonesRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }
    let (hLeft, _) = try await AudioRendererTestSupport.renderFrames(
      headphonesRenderer, total: 16384)
    let headphonesFreq = AudioRendererTestSupport.dominantFrequency(
      hLeft, sampleRate: 48000, minHz: 100, maxHz: 1200)

    // swift-format wraps the closure's `renderer in` onto its own line once
    // the opening-brace line is too long; swiftlint's closure_parameter_position
    // rule wants it on the same line as `{`. Format wins (see
    // ConfigStore.swift for the same kind of workaround, a different rule).
    // swiftlint:disable closure_parameter_position
    let speakersRenderer = try await AudioRendererTestSupport.makeRenderer(config: speakersConfig) {
      renderer in
      // swiftlint:enable closure_parameter_position
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

/// Counts falling threshold-crossings of the carrier's amplitude envelope —
/// i.e. how many gate "dips" occurred — a coarse proxy for pulse count that
/// does not require resolving an exact modulation frequency (useful here
/// since `Config.AudioDistance.pulseRateMinHz` can be as low as 1 Hz, too
/// slow to resolve precisely over a short render).
///
/// The envelope is extracted as **block RMS** (non-overlapping blocks of
/// `blockSize` samples), not a rectified-and-smoothed running average: RMS
/// over a window spanning several carrier periods rejects the carrier
/// almost completely regardless of the carrier's phase at the block
/// boundary (`sin²` integrated over any window much longer than one period
/// converges to a constant), whereas a simple moving average of `|sample|`
/// leaves a residual ripple at the carrier frequency whose threshold
/// crossings can swamp the much slower gate signal this is trying to
/// measure.
private func envelopeDipCount(_ samples: [Float], blockSize: Int) -> Int {
  let blocks = AudioRendererTestSupport.windowedRMS(
    samples, windows: max(1, samples.count / blockSize))
  guard let minValue = blocks.min(), let maxValue = blocks.max(), maxValue > minValue else {
    return 0
  }
  let threshold = (minValue + maxValue) / 2

  var dips = 0
  var wasAbove = (blocks.first ?? 0) > threshold
  for value in blocks {
    let isAbove = value > threshold
    if wasAbove, !isAbove { dips += 1 }
    wasAbove = isAbove
  }
  return dips
}
