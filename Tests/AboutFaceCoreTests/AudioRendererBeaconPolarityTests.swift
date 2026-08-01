import Testing

@testable import AboutFaceCore

/// **Beacon principle (2026-08-01 maintainer directive).** "The sound the
/// user hears should be designed to get them to move... If I need to move
/// to the right, the sound should come from over there so that I am
/// squaring off towards the correct spot." Concretely: pan and pitch encode
/// the *negated* error, not the raw error — getting the sign backwards here
/// is the audio equivalent of the §3.4 inverted-instruction failure mode,
/// so — matching `EgocentricTransformTests`' hand-derived-expectation style
/// — these tests derive the expected direction by hand from
/// `Config.Audio.defaults` rather than relying on a relative comparison.
struct AudioRendererBeaconPolarityTests {

  // MARK: - Pan (horizontal)

  /// Hand-derived expectation (`Config.Audio.defaults.positional`:
  /// `errorRange = 0.35`, `beaconPolarity = true`):
  ///
  /// `errorX = +0.3` ("subject right of target") →
  /// `signMultiplier = -1` (beacon) → `panRaw = -0.3` →
  /// `panNormalized = clamp(-0.3 / 0.35, -1, 1) ≈ -0.857` →
  /// equal-power pan at `-0.857`: `angle = (-0.857 + 1) · pi/4 ≈ 0.112 rad`,
  /// `left = cos(angle) ≈ 0.994`, `right = sin(angle) ≈ 0.112`.
  ///
  /// Left is overwhelmingly dominant: the corrective tone comes from the
  /// subject's LEFT, which is the direction they must move to reach the
  /// target — exactly the beacon principle's worked example ("If I need to
  /// move to the right, the sound should come from over there").
  @Test(
    "Beacon polarity (default): subject right of target (errorX = +0.3) produces LEFT-dominant tone"
  )
  func beaconPolarity_subjectRightOfTarget_producesLeftDominantTone() async throws {
    let target = SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }

    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    let leftRMS = AudioRendererTestSupport.rms(left)
    let rightRMS = AudioRendererTestSupport.rms(right)

    #expect(leftRMS > rightRMS)
    // Hand-derived ratio (~0.994 / 0.112 ≈ 8.9): assert comfortably inside
    // that order of magnitude rather than the exact value, since
    // `equalPowerPan` clamping/rounding is exercised elsewhere.
    #expect(leftRMS > rightRMS * 3)
  }

  /// Symmetric case: subject left of target (`errorX = -0.3`) must produce
  /// a RIGHT-dominant tone (target is to their right; move right to reach
  /// it).
  @Test(
    "Beacon polarity (default): subject left of target (errorX = -0.3) produces RIGHT-dominant tone"
  )
  func beaconPolarity_subjectLeftOfTarget_producesRightDominantTone() async throws {
    let target = SonificationTarget(errorX: -0.3, errorY: 0, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }

    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    let leftRMS = AudioRendererTestSupport.rms(left)
    let rightRMS = AudioRendererTestSupport.rms(right)

    #expect(rightRMS > leftRMS)
    #expect(rightRMS > leftRMS * 3)
  }

  // MARK: - Pitch (vertical)

  /// Hand-derived expectation: `errorY = +0.3` ("subject above target") →
  /// beacon negation → target is BELOW the subject → pitch goes LOW.
  /// `signMultiplier = -1` → `pitchRaw = -0.3` → exponential mapping
  /// (`minHz = 220`, `maxHz = 880`, `errorRange = 0.35`):
  /// `t = (-0.3/0.35 + 1) / 2 ≈ 0.0714`,
  /// `freq = 220 · (880/220)^0.0714 = 220 · 4^0.0714 ≈ 243 Hz` — close to
  /// `minHz`, i.e. low, as expected.
  ///
  /// `errorY = -0.3` ("subject below target") → target is ABOVE → pitch
  /// HIGH: `pitchRaw = +0.3`, `t ≈ 0.929`,
  /// `freq = 220 · 4^0.929 ≈ 797 Hz` — close to `maxHz`.
  @Test("Beacon polarity (default): subject above target (errorY = +0.3) produces LOW-pitched tone")
  func beaconPolarity_subjectAboveTarget_producesLowPitch() async throws {
    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }

    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
    let dominant = AudioRendererTestSupport.dominantFrequency(
      left, sampleRate: 48000, minHz: 220, maxHz: 880)

    // Hand-derived ~243 Hz; allow generous tolerance for the coarse 60-step
    // frequency scan, but require it to land unambiguously in the lower
    // third of the [220, 880] range.
    #expect(dominant < 400)
  }

  @Test(
    "Beacon polarity (default): subject below target (errorY = -0.3) produces HIGH-pitched tone")
  func beaconPolarity_subjectBelowTarget_producesHighPitch() async throws {
    let target = SonificationTarget(errorX: 0, errorY: -0.3, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(target)
    }

    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
    let dominant = AudioRendererTestSupport.dominantFrequency(
      left, sampleRate: 48000, minHz: 220, maxHz: 880)

    // Hand-derived ~797 Hz; require it in the upper third of the range.
    #expect(dominant > 700)
  }

  // MARK: - Flag flip (error-marker polarity, for A/B tuning only)

  /// `beaconPolarity = false` restores the non-negated "error-marker"
  /// polarity: the tone marks where the subject IS, not where the target
  /// is. With `errorX = +0.3` (subject right of target) this must now
  /// produce a RIGHT-dominant tone — the mirror image of the default case
  /// above — proving the flag actually controls the sign and isn't a no-op.
  @Test("beaconPolarity = false flips pan polarity (error-marker convention)")
  func errorMarkerPolarity_subjectRightOfTarget_producesRightDominantTone() async throws {
    var config = Config.Audio.defaults
    config.positional.beaconPolarity = false
    let target = SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false)
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(target)
    }

    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    #expect(AudioRendererTestSupport.rms(right) > AudioRendererTestSupport.rms(left))
  }
}
