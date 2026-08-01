import AVFoundation
import Testing

@testable import AboutFaceCore

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Shared helpers for `AudioRenderer` tests. All of these drive the
/// renderer through `AVAudioEngine`'s manual rendering mode (`.offline`) —
/// deterministic, no real audio device, CI-safe (§13 Phase 3 requirement 6)
/// — and inspect the resulting samples with coarse, robust measurements
/// (RMS balance, dominant frequency via a single-bin Goertzel, spectral
/// flatness) rather than exact sample comparisons.
enum AudioRendererTestSupport {
  /// Starts an offline-mode `AudioRenderer` for `config` and drives `setup`
  /// against it before any rendering happens (e.g. `update(_:)` to install a
  /// steady-state target, or `play(_:)` to queue an earcon).
  static func makeRenderer(
    config: Config.Audio = .defaults,
    setup: (AudioRenderer) async throws -> Void
  ) async throws -> AudioRenderer {
    let renderer = AudioRenderer(config: config, mode: .offline)
    try await renderer.start()
    try await setup(renderer)
    return renderer
  }

  /// Pulls `total` frames from `renderer` in `chunk`-sized calls (manual
  /// rendering mode caps a single pull at the `maximumFrameCount` the
  /// engine was configured with — `AudioRenderer.start()` uses
  /// `bufferFrameSize * 4`, so any `chunk` at or below the default
  /// `bufferFrameSize` (256) is safe for every test's `Config.Audio`)
  /// and concatenates both channels.
  static func renderFrames(
    _ renderer: AudioRenderer, total: Int, chunk: Int = 256
  ) async throws -> (left: [Float], right: [Float]) {
    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(total)
    right.reserveCapacity(total)

    var remaining = total
    while remaining > 0 {
      let n = min(chunk, remaining)
      let samples = try await renderer.renderOffline(frameCount: AVAudioFrameCount(n))
      left.append(contentsOf: samples.left)
      right.append(contentsOf: samples.right)
      remaining -= n
    }
    return (left, right)
  }

  static func rms(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sumSquares / Double(samples.count)).squareRoot()
  }

  /// Splits `samples` into `windows` equal-sized (last one possibly
  /// shorter) contiguous slices and returns each slice's RMS — used to
  /// check an earcon's amplitude envelope shape over time (e.g. "does it
  /// dip to near-zero partway through") without needing exact sample
  /// comparisons.
  static func windowedRMS(_ samples: [Float], windows: Int) -> [Double] {
    guard windows > 0, !samples.isEmpty else { return [] }
    let size = max(1, samples.count / windows)
    var result: [Double] = []
    var start = 0
    for _ in 0..<windows {
      let end = min(start + size, samples.count)
      guard start < end else { break }
      result.append(rms(Array(samples[start..<end])))
      start = end
    }
    return result
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Single-frequency-bin magnitude via the Goertzel algorithm — equivalent
  /// to one DFT bin, much cheaper than a full FFT, and exactly what's
  /// needed to ask "how much energy is there near this one frequency."
  static func goertzelMagnitude(_ samples: [Float], sampleRate: Double, targetHz: Double) -> Double
  {
    // swiftlint:enable opening_brace
    let n = samples.count
    guard n > 0 else { return 0 }
    let k = Double(n) * targetHz / sampleRate
    let omega = 2 * Double.pi * k / Double(n)
    let coeff = 2 * cos(omega)
    var s0 = 0.0
    var s1 = 0.0
    var s2 = 0.0
    for sample in samples {
      s0 = Double(sample) + coeff * s1 - s2
      s2 = s1
      s1 = s0
    }
    let real = s1 - s2 * cos(omega)
    let imag = s2 * sin(omega)
    return (real * real + imag * imag).squareRoot() / Double(n)
  }

  /// Scans `steps` evenly-spaced candidate frequencies between `minHz` and
  /// `maxHz` and returns the one with the largest Goertzel magnitude — the
  /// coarse "dominant frequency" used to assert pitch direction (e.g. "the
  /// dominant frequency when above target is higher than when below").
  static func dominantFrequency(
    _ samples: [Float], sampleRate: Double, minHz: Double, maxHz: Double, steps: Int = 60
  ) -> Double {
    var bestHz = minHz
    var bestMagnitude = -1.0
    for i in 0...steps {
      let hz = minHz + (maxHz - minHz) * Double(i) / Double(steps)
      let magnitude = goertzelMagnitude(samples, sampleRate: sampleRate, targetHz: hz)
      if magnitude > bestMagnitude {
        bestMagnitude = magnitude
        bestHz = hz
      }
    }
    return bestHz
  }

  /// Spectral flatness (Wiener entropy): geometric mean / arithmetic mean of
  /// the magnitude spectrum sampled at `bins` points between `minHz` and
  /// `maxHz`. Close to `1` for broadband/noise-like content, much smaller
  /// than `1` for a tone with energy concentrated at one frequency — used to
  /// assert `faceLost`'s noise burst reads as flatter-spectrum than the
  /// tonal earcons (§6.1: "different in kind").
  static func spectralFlatness(
    _ samples: [Float], sampleRate: Double, minHz: Double, maxHz: Double, bins: Int = 40
  ) -> Double {
    var magnitudes: [Double] = []
    magnitudes.reserveCapacity(bins)
    for i in 0..<bins {
      let hz = minHz + (maxHz - minHz) * Double(i) / Double(bins - 1)
      magnitudes.append(goertzelMagnitude(samples, sampleRate: sampleRate, targetHz: hz) + 1e-9)
    }
    let logSum = magnitudes.reduce(0.0) { $0 + log($1) }
    let geometricMean = exp(logSum / Double(magnitudes.count))
    let arithmeticMean = magnitudes.reduce(0, +) / Double(magnitudes.count)
    guard arithmeticMean > 0 else { return 0 }
    return geometricMean / arithmeticMean
  }
}
