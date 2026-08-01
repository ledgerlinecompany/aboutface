#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Pure, allocation-free math used by the render callback (`RenderState.render`).
/// Everything here is deterministic given its inputs — no glo­bal mutable
/// state, no I/O — which is both what makes it real-time-safe (libm calls
/// like `sin`/`pow`/`tanh` are pure computation: no allocation, no locking,
/// no syscalls) and what makes it directly unit-testable without any audio
/// engine involved.
enum AudioSynthesis {
  /// Maps a normalized value in `[-errorRange, errorRange]` to a frequency
  /// in `[minHz, maxHz]` via exponential (musically-even) interpolation, per
  /// §13 Phase 3 requirement 2 ("pitch ← errorY... exponential frequency
  /// mapping between Config min/max Hz"). `normalized = -errorRange` maps to
  /// `minHz`, `0` maps to the geometric mean of `minHz`/`maxHz`,
  /// `+errorRange` maps to `maxHz`. Values outside the range are clamped,
  /// not extrapolated.
  static func exponentialFrequency(
    normalized: Float,
    range: Float,
    minHz: Double,
    maxHz: Double
  ) -> Double {
    guard range > 0 else { return minHz }
    let clamped = max(-range, min(range, normalized))
    let t = (Double(clamped) / Double(range) + 1) / 2  // 0...1
    return minHz * pow(maxHz / minHz, t)
  }

  /// Equal-power stereo pan law: `pan == -1` is full left, `0` is centered,
  /// `+1` is full right. Equal-power (as opposed to linear) panning keeps
  /// perceived loudness constant as the tone moves across the stereo field,
  /// which matters here because §6.2 explicitly rules out loudness as a
  /// carrier of information — a pan law that dims the tone off-center would
  /// contaminate the pan channel with an unintended loudness cue.
  static func equalPowerPan(_ pan: Float) -> (left: Float, right: Float) {
    let clamped = max(-1, min(1, pan))
    let angle = (Double(clamped) + 1) * .pi / 4  // 0...(pi/2)
    return (Float(cos(angle)), Float(sin(angle)))
  }

  /// Soft clip via `tanh`, applied once to each final output sample. Cheap,
  /// branchless, allocation-free — protects against the rare case of
  /// multiple simultaneous voices (positional tone + Scheme B + an earcon)
  /// summing past full scale, without the harsh distortion of a hard clamp.
  static func softClip(_ sample: Float) -> Float {
    Float(tanh(Double(sample)))
  }

  /// Linear interpolation, clamping `t` to `[0, 1]` first.
  static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * max(0, min(1, t))
  }

  /// xorshift32 — a tiny, fast, deterministic PRNG (Marsaglia 2003). Used
  /// only for the `faceLost` noise-burst earcon. Not cryptographic, and
  /// deliberately not `SystemRandomNumberGenerator` or anything else that
  /// might read from a system entropy source: this must be pure computation
  /// on render-thread-owned state, with zero chance of a syscall.
  static func xorshift32(_ state: inout UInt32) -> UInt32 {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return state
  }

  /// `xorshift32` mapped to a `Float` in `[-1, 1]`.
  static func whiteNoiseSample(_ state: inout UInt32) -> Float {
    let bits = xorshift32(&state)
    // Top 24 bits -> [0, 1), then rescale to [-1, 1).
    let unit = Float(bits >> 8) / Float(1 << 24)
    return unit * 2 - 1
  }

  /// Naive band-limited-free square wave (sign of sine) — deliberately
  /// harmonically rich/harsh, used only for the `noSignal` buzzer earcon
  /// where "buzzer-like" is the entire point (§6.1: "own message... a
  /// different problem with a different fix" deserves a maximally distinct,
  /// alarm-like timbre). Aliasing from the naive (non-band-limited) edges is
  /// acceptable here: this is a short, low-frequency alarm tone, not
  /// program material, and the extra high-frequency content only makes it
  /// buzz harder.
  static func squareWave(phase: Double) -> Float {
    sin(phase) >= 0 ? 1 : -1
  }
}
