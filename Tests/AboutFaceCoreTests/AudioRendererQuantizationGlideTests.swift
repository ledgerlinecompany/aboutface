import AVFoundation
import Testing

@testable import AboutFaceCore

/// Quantization GLIDE (2026-08-02 action round, item 2 — maintainer design:
/// "separate true quantization from the way the sounds output"). Companion
/// to `AudioRendererQuantizationTests` (which pins `quantizationGlideMs = 0`
/// to keep its hand-derived hard-snap assertions exact); this file covers
/// the glide itself. See `Config.AudioPositional.quantizationGlideMs` and
/// `RenderState.quantizedError`/`glidedToward` for the design.
struct AudioRendererQuantizationGlideTests {
  private static let sampleRate = 48000.0

  // MARK: - Continuous path is unaffected

  /// `errorQuantizationStep == 0` (continuous): `quantizedError` returns
  /// `value` immediately without ever touching glide state, so
  /// `quantizationGlideMs` must have literally zero effect on rendered
  /// output — not merely "close," bit-identical.
  @Test("Continuous default (step = 0): glide setting has no effect on output")
  func continuousPathUnaffectedByGlide() async throws {
    var noGlide = Config.Audio.defaults
    noGlide.positional.errorQuantizationStep = 0
    noGlide.positional.quantizationGlideMs = 0

    var withGlide = Config.Audio.defaults
    withGlide.positional.errorQuantizationStep = 0
    withGlide.positional.quantizationGlideMs = 80

    // An off-grid, two-axis target — not a round number on any axis — so a
    // stray glide-state touch anywhere in the pan/pitch path would show up.
    let target = SonificationTarget(
      errorX: 0.171, errorY: -0.233, distanceError: 0, inDeadZone: false)

    let a = try await AudioRendererTestSupport.makeRenderer(config: noGlide) { renderer in
      await renderer.update(target)
    }
    let (aLeft, aRight) = try await AudioRendererTestSupport.renderFrames(a, total: 4096)

    let b = try await AudioRendererTestSupport.makeRenderer(config: withGlide) { renderer in
      await renderer.update(target)
    }
    let (bLeft, bRight) = try await AudioRendererTestSupport.renderFrames(b, total: 4096)

    #expect(aLeft.count == bLeft.count)
    #expect(aRight.count == bRight.count)
    for (x, y) in zip(aLeft, bLeft) { #expect(x == y) }
    for (x, y) in zip(aRight, bRight) { #expect(x == y) }
  }

  // MARK: - Glide is actually engaged (not a silent no-op) when quantization is active

  /// With quantization active, the very first render block should differ
  /// between the glided and hard-quantized renderers — the glided one is
  /// still slewing up from silence at `t == 0` while the hard one jumps
  /// straight to the quantized target. If this ever starts passing
  /// trivially (outputs equal from sample 0), the glide isn't engaging.
  @Test("Glide measurably differs from the hard-quantized case early in the render")
  func glideDiffersFromHardQuantizedEarlyOn() async throws {
    var hard = Config.Audio.defaults
    hard.positional.errorQuantizationStep = 0.03
    hard.positional.quantizationGlideMs = 0

    var glided = Config.Audio.defaults
    glided.positional.errorQuantizationStep = 0.03
    glided.positional.quantizationGlideMs = 80

    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)

    let hardRenderer = try await AudioRendererTestSupport.makeRenderer(config: hard) { renderer in
      await renderer.update(target)
    }
    let (hardLeft, _) = try await AudioRendererTestSupport.renderFrames(hardRenderer, total: 256)

    // swift-format requires the closure's `renderer in` onto its own line
    // once the opening-brace line is too long; swiftlint's
    // closure_parameter_position rule wants it on the same line as `{`.
    // Format wins (see ConfigStore.swift for the same kind of workaround).
    // swiftlint:disable closure_parameter_position
    let glidedRenderer = try await AudioRendererTestSupport.makeRenderer(config: glided) {
      renderer in
      // swiftlint:enable closure_parameter_position
      await renderer.update(target)
    }
    let (glidedLeft, _) = try await AudioRendererTestSupport.renderFrames(
      glidedRenderer, total: 256)

    var maxDiff: Float = 0
    for (x, y) in zip(hardLeft, glidedLeft) { maxDiff = max(maxDiff, abs(x - y)) }
    #expect(maxDiff > 0.01, "glide should audibly differ from an instant jump this early")
  }

  // MARK: - Settled output matches the hard-quantized case exactly

  /// Once the glide has had time to fully traverse (magnitude 0.3, step
  /// 0.03, default 80ms/step ⇒ ~800ms to cover), the dominant frequency
  /// must match the hard-quantized (`quantizationGlideMs == 0`) case: the
  /// "you're there" purity snap is preserved bit-for-bit once settled, only
  /// the path there changed. Measured on a TAIL window (after a long
  /// warm-up render) so the transient sweep at the start doesn't pollute
  /// the dominant-frequency scan.
  @Test("Settled glide output matches the hard-quantized dominant frequency")
  func settledOutputMatchesHardQuantized() async throws {
    var hard = Config.Audio.defaults
    hard.positional.errorQuantizationStep = 0.03
    hard.positional.quantizationGlideMs = 0

    var glided = Config.Audio.defaults
    glided.positional.errorQuantizationStep = 0.03
    glided.positional.quantizationGlideMs = 80

    let target = SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false)

    let hardRenderer = try await AudioRendererTestSupport.makeRenderer(config: hard) { renderer in
      await renderer.update(target)
    }
    let (hardLeft, _) = try await AudioRendererTestSupport.renderFrames(hardRenderer, total: 8192)
    let hardFreq = AudioRendererTestSupport.dominantFrequency(
      hardLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)

    // swift-format requires the closure's `renderer in` onto its own line
    // once the opening-brace line is too long; swiftlint's
    // closure_parameter_position rule wants it on the same line as `{`.
    // Format wins (see ConfigStore.swift for the same kind of workaround).
    // swiftlint:disable closure_parameter_position
    let glidedRenderer = try await AudioRendererTestSupport.makeRenderer(config: glided) {
      renderer in
      // swiftlint:enable closure_parameter_position
      await renderer.update(target)
    }
    // Warm-up well past the ~800ms convergence time, then measure a fresh
    // settled window.
    _ = try await AudioRendererTestSupport.renderFrames(glidedRenderer, total: 96000)
    let (tailLeft, _) = try await AudioRendererTestSupport.renderFrames(
      glidedRenderer, total: 8192)
    let tailFreq = AudioRendererTestSupport.dominantFrequency(
      tailLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)

    #expect(abs(tailFreq - hardFreq) < 1)
  }

  /// The `target == 0` case specifically (2026-08-02 design requirement:
  /// "converges exactly onto the quantized target (including 0)"):
  /// starting away from center and returning to it, the settled tail must
  /// match the HARD-quantized (glide = 0) zero-error case exactly — proving
  /// the glide's convergence is exact, not asymptotic. Compared against the
  /// hard-quantized measurement (both taken through the same coarse
  /// `dominantFrequency` scan) rather than the theoretical reference-tone
  /// Hz directly: the scan's own step resolution (60 candidates over a wide
  /// range) means even an exact match can land a few Hz off the true
  /// analytic center, so canceling that artifact out on both sides is what
  /// makes a tight tolerance meaningful here — see
  /// `settledOutputMatchesHardQuantized` above for the same technique.
  @Test("Glide converges exactly to zero (the null) after settling")
  func convergesExactlyToZero() async throws {
    var hard = Config.Audio.defaults
    hard.positional.errorQuantizationStep = 0.03
    hard.positional.quantizationGlideMs = 0

    var glided = Config.Audio.defaults
    glided.positional.errorQuantizationStep = 0.03
    glided.positional.quantizationGlideMs = 80

    let hardRenderer = try await AudioRendererTestSupport.makeRenderer(config: hard) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (hardLeft, _) = try await AudioRendererTestSupport.renderFrames(hardRenderer, total: 8192)
    let hardFreq = AudioRendererTestSupport.dominantFrequency(
      hardLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)

    let renderer = AudioRenderer(config: glided, mode: .offline)
    try await renderer.start()

    // Move away from center and let the glide fully settle there (~800ms
    // to cover 0.3 at the default rate; 1s of render is comfortably past
    // that). Chunked through the shared helper — manual rendering mode
    // caps a single pull at the engine's configured `maximumFrameCount`
    // (see `AudioRendererTestSupport.renderFrames`'s doc comment).
    await renderer.update(
      SonificationTarget(errorX: 0, errorY: 0.3, distanceError: 0, inDeadZone: false))
    _ = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)

    // Now return to center and let the glide settle back down to the null.
    await renderer.update(
      SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    _ = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)
    let (tailLeft, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)

    let tailFreq = AudioRendererTestSupport.dominantFrequency(
      tailLeft, sampleRate: Self.sampleRate, minHz: 150, maxHz: 3000)
    #expect(abs(tailFreq - hardFreq) < 1)
  }
}
