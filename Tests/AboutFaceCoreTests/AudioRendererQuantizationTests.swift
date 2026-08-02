import Testing

@testable import AboutFaceCore

/// Sonification quantization (2026-08-02 maintainer experiment): with
/// `errorQuantizationStep > 0` the beacon moves in discrete levels; with
/// the default `0` it is continuous. Trials compare centering ease vs
/// settle steadiness across step sizes.
struct AudioRendererQuantizationTests {

  private func config(step: Double) -> Config.Audio {
    var audio = Config.Audio.defaults
    audio.positional.errorQuantizationStep = step
    // Pinned to 0 (2026-08-02 action round, item 2): these tests assert the
    // hard-quantized snap itself (same-step ⇒ same pitch, near-center ⇒
    // exact purity) over a render window that starts from silence, which a
    // nonzero `quantizationGlideMs` would smear into a transient sweep
    // rather than the exact snapped pitch these hand-derived assertions
    // expect. The glide itself (including "settles to the same output as
    // the hard-quantized case") is covered on its own terms by
    // `AudioRendererQuantizationGlideTests`.
    audio.positional.quantizationGlideMs = 0
    return audio
  }

  @Test("Two errors within one step render the identical dominant frequency")
  func sameStepSamePitch() async throws {
    // step 0.1: errorY 0.28 and 0.32 both snap (post-polarity) to 0.3.
    var freqs: [Double] = []
    for errorY in [Float(0.28), Float(0.32)] {
      let renderer = try await AudioRendererTestSupport.makeRenderer(config: config(step: 0.1)) {
        await $0.update(
          SonificationTarget(errorX: 0, errorY: errorY, distanceError: 0, inDeadZone: false))
      }
      let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
      freqs.append(
        AudioRendererTestSupport.dominantFrequency(left, sampleRate: 48000, minHz: 150, maxHz: 3000)
      )
    }
    #expect(abs(freqs[0] - freqs[1]) < 1, "same step must sound identical: \(freqs)")
  }

  @Test("Near-center error snaps to exactly zero: quantization composes with the purity anchor")
  func nearCenterSnapsToPurity() async throws {
    // step 0.1: |errorY| = 0.04 rounds to 0 -> pure center tone (reference
    // frequency, no timbre ingredient) even though the raw error is nonzero.
    let quantized = try await AudioRendererTestSupport.makeRenderer(config: config(step: 0.1)) {
      await $0.update(
        SonificationTarget(errorX: 0, errorY: 0.04, distanceError: 0, inDeadZone: false))
    }
    let continuous = try await AudioRendererTestSupport.makeRenderer(config: config(step: 0)) {
      await $0.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (qLeft, _) = try await AudioRendererTestSupport.renderFrames(quantized, total: 16384)
    let (cLeft, _) = try await AudioRendererTestSupport.renderFrames(continuous, total: 16384)
    let qFreq = AudioRendererTestSupport.dominantFrequency(
      qLeft, sampleRate: 48000, minHz: 150, maxHz: 3000)
    let cFreq = AudioRendererTestSupport.dominantFrequency(
      cLeft, sampleRate: 48000, minHz: 150, maxHz: 3000)
    #expect(abs(qFreq - cFreq) < 1, "snapped-to-zero must equal true center: \(qFreq) vs \(cFreq)")
  }

  @Test("Step 0 (default) is exact pass-through: distinct errors render distinct pitches")
  func continuousDefaultDistinguishes() async throws {
    // Wider separation than the same-step pair: near the low end of the
    // exponential mapping, 0.28 vs 0.32 land ~18 Hz apart — below the
    // dominant-frequency scan resolution. 0.12 vs 0.36 are >100 Hz apart.
    var freqs: [Double] = []
    for errorY in [Float(0.12), Float(0.36)] {
      let renderer = try await AudioRendererTestSupport.makeRenderer(config: config(step: 0)) {
        await $0.update(
          SonificationTarget(errorX: 0, errorY: errorY, distanceError: 0, inDeadZone: false))
      }
      let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 16384)
      freqs.append(
        AudioRendererTestSupport.dominantFrequency(left, sampleRate: 48000, minHz: 150, maxHz: 3000)
      )
    }
    #expect(abs(freqs[0] - freqs[1]) > 5, "continuous beacon must distinguish: \(freqs)")
  }
}
