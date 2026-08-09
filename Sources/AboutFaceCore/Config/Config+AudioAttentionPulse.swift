/// Phase 4.5's ATTENTION pulse (`docs/design/phase-4.5-app-design.md` §3.3.1)
/// — the status pulse's other character, played in the heartbeat's slot and on
/// its cadence when something durable and non-severe is wrong.
///
/// A **double tap slightly below the heartbeat's pitch**. Two cues carry the
/// same single bit — rhythm and pitch — because redundant coding survives a
/// laptop speaker and a talking colleague better than either alone. The design
/// names the risk this shape stands or falls on: two quiet sounds must stay
/// distinguishable after an hour of habituation, which is an `audition`
/// question rather than a reasoning one. Every value here is therefore a
/// starting point for the maintainer's ear (§0), not a tuned constant.
///
/// Declared top-level rather than nested inside `Config.AudioHeartbeat` for
/// SwiftLint's `nesting` depth limit — the same reason
/// `CameraModeCaptureSettings` sits beside `Config.Camera` instead of within
/// it.
public struct AudioAttentionPulse: Codable, Sendable, Equatable {
  /// Matched to the heartbeat's gain by default, but for a narrower reason
  /// than "don't be alarming."
  ///
  /// **Maintainer, 2026-08-07: "you won't hear the error one every 7 seconds,
  /// because it means something is wrong."** The heartbeat is the sound heard
  /// a thousand times across a two-hour call, so habituation and fatigue are
  /// ITS constraints. This one plays only while something is actually wrong,
  /// which — if the rest of the design works — is rare and brief. Its
  /// constraint is therefore not "must not fatigue" but **"must be
  /// unmistakable."**
  ///
  /// That distinction matters for tuning: raising `drive` or `gain` here does
  /// not carry the long-session cost it would on the heartbeat, so neither is
  /// the knob to pull back first if this feels strong. It still should not be
  /// ALARMING — these conditions are non-severe by definition, and a user who
  /// cannot immediately correct their position would hear it on every cadence
  /// until they could — but "not alarming" is a much weaker requirement than
  /// "not fatiguing," and the two were conflated when this was first written.
  public var gain: Double
  /// Below the heartbeat's 880 Hz, giving pitch as a second, redundant cue
  /// alongside the rhythm.
  public var freqHz: Double
  /// Each of the two taps. Roughly two thirds of the heartbeat's single note,
  /// so the pair occupies a comparable span rather than sprawling.
  public var noteDurationMs: Double
  /// Silence between the taps. Short enough to hear as ONE gesture rather than
  /// two separate pulses — the distinction the bit rests on is "one tap or
  /// two," which only reads if the two arrive together.
  public var gapMs: Double

  /// Attack, milliseconds — how fast each tap reaches full amplitude.
  ///
  /// **Maintainer field finding, 2026-08-07: "it's a little soft for an onset
  /// to tell it's a double."** Every other earcon uses the shared
  /// `sin(pi * t / duration)` window, which is symmetric: a 55ms tap fades IN
  /// over ~27ms. That is fine for a single sustained cue and fatal for a pair,
  /// because a listener counts ONSETS, not tones, and a fade-in has no onset
  /// to count. A percussive attack of a few milliseconds followed by
  /// exponential decay is what makes two taps read as two.
  public var attackMs: Double

  /// Decay shape, as the exponential's time constant divided into the note's
  /// remaining length. Larger = tighter, more percussive.
  public var decayCurve: Double

  /// Harmonic drive, 0...1. `0` is the pure sine this started as; higher
  /// values waveshape it toward something reedier via gain-normalized `tanh`,
  /// the same primitive `RenderState+VerticalTimbre`'s overdrive uses.
  ///
  /// This matters for the same reason the attack does: an onset is *audible*
  /// in proportion to its high-frequency content, so a pure sine's transient
  /// is nearly inaudible however fast the attack. Drive puts energy up where
  /// the ear locates attacks. The maintainer's own words for this register,
  /// recorded in `RenderState+VerticalTimbre.swift`: "something a little more
  /// overdriven? Or mix in a saw or something?"
  public var drive: Double

  public init(
    gain: Double, freqHz: Double, noteDurationMs: Double, gapMs: Double,
    attackMs: Double = 2.5, decayCurve: Double = 3.5, drive: Double = 0.7
  ) {
    self.gain = gain
    self.freqHz = freqHz
    self.noteDurationMs = noteDurationMs
    self.gapMs = gapMs
    self.attackMs = attackMs
    self.decayCurve = decayCurve
    self.drive = drive
  }
}
