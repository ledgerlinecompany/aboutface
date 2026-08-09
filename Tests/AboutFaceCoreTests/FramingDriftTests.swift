import Testing

@testable import AboutFaceCore

/// `FramingDrift` — the primary signal behind Phase 4.5's status pulse, after
/// a live session showed edge-cropping was effectively unreachable.
struct FramingDriftTests {
  private static let deadZone = Config.defaults.deadZone

  private static func framing(x: Float = 0, y: Float = 0, distance: Float = 0) -> FramingState {
    FramingState(
      error: SIMD2<Float>(x, y), distanceError: distance, inDeadZone: false,
      gazeOnCamera: true, headLevel: true)
  }

  @Test("Dead centre has not drifted")
  func centredHasNotDrifted() {
    #expect(
      !FramingDrift.hasDrifted(framing: Self.framing(), deadZone: Self.deadZone, multiplier: 2))
  }

  /// The band between the dead zone and the drift boundary is the ordinary
  /// working range — small corrections happen there constantly and must not
  /// raise the bit.
  @Test("Just outside the dead zone but inside the drift boundary is still quiet")
  func insideDriftBoundaryIsQuiet() {
    let justOutside = Float(Self.deadZone.horizontal * 1.5)
    #expect(
      !FramingDrift.hasDrifted(
        framing: Self.framing(x: justOutside), deadZone: Self.deadZone, multiplier: 2))
  }

  @Test("Beyond twice the dead zone counts as drifted, on each axis independently")
  func beyondBoundaryCountsPerAxis() {
    let horizontal = Float(Self.deadZone.horizontal * 2.5)
    let vertical = Float(Self.deadZone.vertical * 2.5)
    let distance = Float(Self.deadZone.distance * 2.5)
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(x: horizontal), deadZone: Self.deadZone, multiplier: 2))
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(y: vertical), deadZone: Self.deadZone, multiplier: 2))
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(distance: distance), deadZone: Self.deadZone, multiplier: 2))
  }

  /// Being badly off on one axis is not excused by being perfect on the other
  /// two — §4 treats the axes as independently satisfiable for the same reason.
  @Test("One bad axis is enough, even with the others perfect")
  func oneBadAxisIsEnough() {
    let horizontal = Float(Self.deadZone.horizontal * 3)
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(x: horizontal, y: 0, distance: 0), deadZone: Self.deadZone,
        multiplier: 2))
  }

  @Test("Drift is symmetric: negative errors count the same as positive")
  func driftIsSymmetric() {
    let magnitude = Float(Self.deadZone.horizontal * 2.5)
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(x: magnitude), deadZone: Self.deadZone, multiplier: 2))
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(x: -magnitude), deadZone: Self.deadZone, multiplier: 2))
  }

  /// A multiplier below 1 would put the warn boundary INSIDE the good zone, so
  /// the pulse would flag a user the app simultaneously considers well placed.
  /// A nonsensical config degrades to "never warns," never to "always warns."
  @Test("A multiplier below 1 never reports drift")
  func degenerateMultiplierNeverWarns() {
    let far = Float(Self.deadZone.horizontal * 10)
    #expect(
      !FramingDrift.hasDrifted(
        framing: Self.framing(x: far), deadZone: Self.deadZone, multiplier: 0.5))
  }

  /// Widening the multiplier must make the bit rarer, not more common.
  @Test("A wider multiplier tolerates more drift")
  func widerMultiplierToleratesMore() {
    let error = Float(Self.deadZone.horizontal * 2.5)
    #expect(
      FramingDrift.hasDrifted(
        framing: Self.framing(x: error), deadZone: Self.deadZone, multiplier: 2))
    #expect(
      !FramingDrift.hasDrifted(
        framing: Self.framing(x: error), deadZone: Self.deadZone, multiplier: 4))
  }
}
