import AVFoundation
import Testing

@testable import AboutFaceCore

/// §6.2 round-4 maintainer tuning directive ("directional distance"):
/// acceptance tests for the distance gate's new too-close/too-far pulse
/// CHARACTER (not just rate), the purity anchor (zero error is genuinely
/// steady), rate still tracking `|distanceError|` for both signs,
/// `Config.AudioDistance.directionalPulseEnabled == false` restoring the
/// single legacy shape, and sign-flip continuity (no click as
/// `distanceError` crosses zero). See `RenderState.distanceGate`'s doc
/// comment for the full derivation these tests check against.
struct AudioRendererDistanceDirectionTests {

  // MARK: - Sign distinction: too-close chops vs. too-far swell

  @Test("Too-close and too-far gate envelopes have measurably different duty cycles")
  func signDistinguishesGateShape() async throws {
    let closeRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.3, inDeadZone: false))
    }
    let (closeLeft, _) = try await AudioRendererTestSupport.renderFrames(
      closeRenderer, total: 48000)
    let closeDuty = dutyBelowMidpoint(closeLeft, blockSize: 480)

    let farRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: -0.3, inDeadZone: false))
    }
    let (farLeft, _) = try await AudioRendererTestSupport.renderFrames(farRenderer, total: 48000)
    let farDuty = dutyBelowMidpoint(farLeft, blockSize: 480)

    // Hand-derived (Config.Audio.defaults: errorRange 0.3, closePulseSharpness
    // 3.5): at |distanceError| == errorRange (t == 1), the too-close shape is
    // `oscillation ^ closePulseSharpness`, where `oscillation ==
    // sin²(pulsePhase / 2)`. The fraction of a cycle spent below the gate's
    // own midpoint (`oscillation ^ k > 0.5`, i.e. the "dip") is
    // `1 - (2/π)·arcsin(0.5^(1/2k))` ≈ 0.28 at k = 3.5 — a narrow, brief dip
    // (a "chop"). The too-far shape is the unmodified `oscillation` (k = 1),
    // symmetric by construction — exactly half a cycle below its own
    // midpoint, duty ≈ 0.5 (a smooth, wide "swell"). Both numbers are
    // generously margined below to absorb block-RMS quantization noise.
    #expect(closeDuty < 0.4)
    #expect(farDuty > 0.35)
    #expect(closeDuty < farDuty)
  }

  // MARK: - Purity anchor: zero error is genuinely steady

  @Test("Round-4b depth contrast: close chops cut far deeper than the far swell")
  func closeCutsDeeperThanFarSwell() async throws {
    // Maintainer directive: "the volume changes in the choppy section need
    // to be more aggressive with the speed being the indicator." At equal
    // |distanceError| (full scale), the close side's minimum block RMS must
    // sit far below the far side's — depth of cut is the direction cue.
    // Defaults: closePulseDepth 0.95 → gate dips to ~0.05 at the chop
    // bottom; farPulseDepth 0.4 → swell floor ~0.6. Comparing minimum
    // block-RMS as a fraction of each side's own maximum makes the check
    // robust to overall gain.
    let closeRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.35, inDeadZone: false))
    }
    let (closeLeft, _) = try await AudioRendererTestSupport.renderFrames(
      closeRenderer, total: 48000)
    let farRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: -0.35, inDeadZone: false))
    }
    let (farLeft, _) = try await AudioRendererTestSupport.renderFrames(farRenderer, total: 48000)

    func envelopeFloorRatio(_ samples: [Float]) -> Double {
      let windows = AudioRendererTestSupport.windowedRMS(samples, windows: 96)
      guard let maxRMS = windows.max(), maxRMS > 0 else { return 1 }
      return (windows.min() ?? maxRMS) / maxRMS
    }

    let closeFloor = envelopeFloorRatio(closeLeft)
    let farFloor = envelopeFloorRatio(farLeft)
    #expect(closeFloor < 0.25, "close chops should cut near silence, floor=\(closeFloor)")
    #expect(farFloor > 0.45, "far swell should stay shallow, floor=\(farFloor)")
    #expect(closeFloor < farFloor)
  }

  @Test("Zero distance error produces no amplitude modulation (flat envelope)")
  func zeroErrorIsSteady() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)
    let blocks = AudioRendererTestSupport.windowedRMS(left, windows: 100)
    guard let minValue = blocks.min(), let maxValue = blocks.max(), maxValue > 0 else {
      Issue.record("Expected nonzero tone output")
      return
    }
    // Before round 4, `pulseRateMinHz` (1 Hz, not 0) meant the gate kept
    // oscillating at full `pulseDepth` even at zero distance error —
    // "steady tone = distance correct" wasn't actually true. Fixed by
    // scaling the gate DEPTH (not just the rate) by
    // `|distanceError| / errorRange`, which is exactly 0 here, so the
    // envelope must be flat within a tight tolerance (block-RMS
    // quantization noise only, not a residual tremolo).
    #expect((maxValue - minValue) / maxValue < 0.02)
  }

  // MARK: - Rate still tracks |distanceError| for both signs

  @Test("Too-close pulse rate increases with |distanceError|")
  func tooCloseRateTracksMagnitude() async throws {
    try await assertRateTracksMagnitude(sign: 1)
  }

  @Test("Too-far pulse rate increases with |distanceError|")
  func tooFarRateTracksMagnitude() async throws {
    try await assertRateTracksMagnitude(sign: -1)
  }

  private func assertRateTracksMagnitude(sign: Float) async throws {
    let smallRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: sign * 0.03, inDeadZone: false))
    }
    let (smallLeft, _) = try await AudioRendererTestSupport.renderFrames(
      smallRenderer, total: 48000)
    let smallDips = AudioRendererTestSupport.envelopeDipCount(smallLeft, blockSize: 480)

    let largeRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: sign * 0.3, inDeadZone: false))
    }
    let (largeLeft, _) = try await AudioRendererTestSupport.renderFrames(
      largeRenderer, total: 48000)
    let largeDips = AudioRendererTestSupport.envelopeDipCount(largeLeft, blockSize: 480)

    // Same shape of assertion as (and consistent with)
    // AudioRendererPositionalTests.distanceErrorMagnitudeIncreasesPulseRate,
    // duplicated per sign here since that test only ever exercised the
    // too-close (positive) direction.
    #expect(largeDips > smallDips)
  }

  // MARK: - directionalPulseEnabled = false: legacy, sign-independent shape

  @Test("Disabling directional pulse makes too-close and too-far envelopes match")
  func directionalPulseDisabledIsSignIndependent() async throws {
    var config = Config.Audio.defaults
    config.distance.directionalPulseEnabled = false

    // swift-format wraps the closure's `renderer in` onto its own line once
    // the opening-brace line is too long; swiftlint's closure_parameter_position
    // rule wants it on the same line as `{`. Format wins (see
    // ConfigStore.swift for the same kind of workaround, a different rule).
    // swiftlint:disable closure_parameter_position
    let closeRenderer = try await AudioRendererTestSupport.makeRenderer(config: config) {
      renderer in
      // swiftlint:enable closure_parameter_position
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0.3, inDeadZone: false))
    }
    let (closeLeft, _) = try await AudioRendererTestSupport.renderFrames(
      closeRenderer, total: 48000)

    // swiftlint:disable closure_parameter_position
    let farRenderer = try await AudioRendererTestSupport.makeRenderer(config: config) {
      renderer in
      // swiftlint:enable closure_parameter_position
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: -0.3, inDeadZone: false))
    }
    let (farLeft, _) = try await AudioRendererTestSupport.renderFrames(farRenderer, total: 48000)

    // With `directionalPulseEnabled == false`, `distanceGate` never
    // consults the SIGN of `distanceError` — only its scaled magnitude
    // (`t`), which is identical for +0.3 and -0.3 — so the two renders must
    // produce bit-identical audio (same carrier, same pan, same gate math
    // start to finish).
    #expect(closeLeft.count == farLeft.count)
    for (a, b) in zip(closeLeft, farLeft) {
      #expect(abs(a - b) < 1e-6)
    }
  }

  // MARK: - Sign-flip continuity: no click as distanceError crosses zero

  @Test("Gate stays continuous as distanceError ramps through zero")
  func signFlipStaysContinuous() async throws {
    let renderer = AudioRenderer(config: .defaults, mode: .offline)
    try await renderer.start()

    // Step distanceError linearly from +0.3 (too close) to -0.3 (too far)
    // in small enough increments (100 steps, one 480-frame/10ms render
    // chunk each) that a genuine "click" bug — e.g. switching gate shape
    // on the sign of distanceError WITHOUT scaling depth toward 0 near the
    // crossing — would show up as an outlier jump in the block-RMS
    // envelope right at the crossing step, distinguishable from the ramp's
    // normal block-to-block variation elsewhere.
    let steps = 100
    let chunk: AVAudioFrameCount = 480
    var blockRMS: [Double] = []
    blockRMS.reserveCapacity(steps)
    var crossingIndex = -1
    for step in 0..<steps {
      let progress = Float(step) / Float(steps - 1)
      let value: Float = 0.3 - 0.6 * progress
      if crossingIndex < 0, value <= 0 { crossingIndex = step }
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: value, inDeadZone: false))
      let samples = try await renderer.renderOffline(frameCount: chunk)
      blockRMS.append(AudioRendererTestSupport.rms(samples.left))
    }

    #expect(crossingIndex > 0)
    #expect(crossingIndex < steps - 1)
    guard crossingIndex > 0, crossingIndex < steps - 1 else { return }

    let deltas = zip(blockRMS, blockRMS.dropFirst()).map { abs($1 - $0) }
    let crossingDeltaIndex = crossingIndex - 1
    let crossingDelta = deltas[crossingDeltaIndex]
    let otherDeltas = deltas.enumerated().filter { $0.offset != crossingDeltaIndex }.map(\.element)
    let averageOtherDelta = otherDeltas.reduce(0, +) / Double(max(1, otherDeltas.count))

    // No explicit crossfade exists at the sign flip (see
    // `RenderState.distanceGate`'s doc comment) — continuity instead falls
    // out of the gate depth itself scaling to 0 as |distanceError| -> 0, so
    // the block-to-block change right at the crossing must be unremarkable
    // relative to the ramp's typical block-to-block change elsewhere, not a
    // standout spike. `0.01` is an absolute floor (in gate-multiplier
    // units) well below a single render chunk's worth of legitimate
    // amplitude change, in case `averageOtherDelta` is near 0.
    #expect(crossingDelta < max(0.01, 3 * averageOtherDelta))
  }
}

/// Fraction of a pulse period the gate sits BELOW its own midpoint (i.e. in
/// the dip) — low for a narrow "chop" (too close), close to 0.5 for a wide,
/// symmetric "swell" (too far). See `signDistinguishesGateShape`'s doc
/// comment for the hand-derived expected values.
private func dutyBelowMidpoint(_ samples: [Float], blockSize: Int) -> Double {
  let blocks = AudioRendererTestSupport.windowedRMS(
    samples, windows: max(1, samples.count / blockSize))
  guard let minValue = blocks.min(), let maxValue = blocks.max(), maxValue > minValue else {
    return 0
  }
  let midpoint = (minValue + maxValue) / 2
  let belowCount = blocks.filter { $0 < midpoint }.count
  return Double(belowCount) / Double(blocks.count)
}
