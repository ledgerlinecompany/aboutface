import Foundation

/// `Config.AudioDistance` — split from `Config+Audio.swift` purely for
/// SwiftLint's `file_length` limit (same pattern as
/// `Config+AudioGazeTrim.swift` / `Config+AudioEarcons.swift`).
extension Config {
  /// §6.2: "Distance maps to pulse rate or filter brightness. Never
  /// volume." The pulse is an amplitude *gate* (tremolo), which is a
  /// temporal/rate parameter, not a loudness parameter — peak amplitude
  /// (`AudioPositional.toneGain`) is untouched by distance; only how fast
  /// the gate cycles changes. This is the resolution to the apparent
  /// tension with "never volume": that rule is about the *base* loudness
  /// being confounded with system output level and user attention, not
  /// about whether a rate-coded gate is allowed to exist at all.
  public struct AudioDistance: Codable, Sendable, Equatable {
    /// `|distanceError|` magnitude that maps to `pulseRateMaxHz`; beyond
    /// this the rate clamps rather than continuing to increase.
    public var errorRange: Double
    /// Gate rate (Hz) at zero distance error.
    public var pulseRateMinHz: Double
    /// Gate rate (Hz) at `errorRange` distance error.
    public var pulseRateMaxHz: Double
    /// Gate depth, 0...1: fraction of `AudioPositional.toneGain` the tone
    /// dips by at the bottom of each gate cycle, at the OUTER edge of
    /// `errorRange`, when TOO CLOSE (`distanceError > 0`). Round-4b
    /// maintainer directive ("the volume changes in the choppy section
    /// need to be more aggressive, with the speed being the indicator"):
    /// the close side's chops cut nearly to silence (default `0.95`) so
    /// depth-of-cut is unmistakably the direction cue, while pulse RATE
    /// stays the urgency cue on both sides. Depth still scales to `0` as
    /// `|distanceError|` approaches `0` (purity anchor) — `0` = no gating
    /// ever; `1` = full on/off at the outer edge.
    public var closePulseDepth: Double
    /// As `closePulseDepth`, for the TOO FAR side's smooth swell
    /// (`distanceError <= 0`, and both sides when
    /// `directionalPulseEnabled == false`). Deliberately shallow (default
    /// `0.4`) so the swell breathes rather than cuts — the depth CONTRAST
    /// between the two sides is the point. (Replaces the former shared
    /// `pulseDepth`; old stored configs' `pulseDepth` key is preserved by
    /// `ConfigStore`'s unknown-key round-trip but no longer read — both
    /// new keys fill from defaults via lenient decode.)
    public var farPulseDepth: Double
    /// **Directional pulse character (§6.2 round-4 maintainer tuning
    /// directive).** `true` (default): the gate's dip SHAPE differs by the
    /// sign of `distanceError` — sharp, clipped chops when too close
    /// (`distanceError > 0`), a smooth wide swell when too far — see
    /// `RenderState.distanceGate`. `false` restores the single-shape
    /// (smooth swell) legacy gate for both signs.
    public var directionalPulseEnabled: Bool
    /// `directionalPulseEnabled` only: the exponent `k` the too-close dip's
    /// raised cosine (`oscillation`, `0...1`) is raised to
    /// (`oscillation ^ k`), narrowing the dip into a brief "chop" the
    /// higher `k` goes. Default `3.5`, clamped to a `0.1` floor at the call
    /// site against a degenerate configured value.
    public var closePulseSharpness: Double

    public init(
      errorRange: Double,
      pulseRateMinHz: Double,
      pulseRateMaxHz: Double,
      closePulseDepth: Double,
      farPulseDepth: Double,
      directionalPulseEnabled: Bool,
      closePulseSharpness: Double
    ) {
      self.errorRange = errorRange
      self.pulseRateMinHz = pulseRateMinHz
      self.pulseRateMaxHz = pulseRateMaxHz
      self.closePulseDepth = closePulseDepth
      self.farPulseDepth = farPulseDepth
      self.directionalPulseEnabled = directionalPulseEnabled
      self.closePulseSharpness = closePulseSharpness
    }
  }
}
