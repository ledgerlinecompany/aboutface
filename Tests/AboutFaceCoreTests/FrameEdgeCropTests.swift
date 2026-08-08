import CoreGraphics
import Testing

@testable import AboutFaceCore

/// `FrameEdgeCrop` — the "partially out of frame" signal §7.4's
/// `.partiallyOutOfFrame` rung has been waiting for since Phase 3.
///
/// The obstacle its own stub named: *"`FaceGeometry` doesn't currently
/// distinguish 'small/far away' from 'cropped by the frame edge'."* Both give
/// a small box, because Vision clips the box to the frame. What separates them
/// is position, not size — which is exactly what the first two tests pin.
struct FrameEdgeCropTests {
  private static func box(x: Double, y: Double, w: Double, h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
  }

  /// The distinction the whole type exists for.
  @Test("A small face floating in the middle is NOT cropped")
  func distantFaceIsNotCropped() {
    let distant = Self.box(x: 0.45, y: 0.45, w: 0.10, h: 0.12)
    #expect(!FrameEdgeCrop.isCropped(boundingBox: distant, margin: 0.01, flagsTopEdge: false))
  }

  @Test("A same-sized face pressed against the left edge IS cropped")
  func faceAgainstLeftEdgeIsCropped() {
    let cropped = Self.box(x: 0.0, y: 0.45, w: 0.10, h: 0.12)
    #expect(FrameEdgeCrop.isCropped(boundingBox: cropped, margin: 0.01, flagsTopEdge: false))
  }

  @Test("A face pressed against the right edge is cropped")
  func faceAgainstRightEdgeIsCropped() {
    let cropped = Self.box(x: 0.90, y: 0.45, w: 0.10, h: 0.12)
    #expect(FrameEdgeCrop.isCropped(boundingBox: cropped, margin: 0.01, flagsTopEdge: false))
  }

  /// `minY` is the BOTTOM edge in the y-up convention Vision uses and
  /// `EgocentricTransform` preserves (it flips X only) — the chin end, and the
  /// vertical case actually worth catching.
  @Test("A face pressed against the bottom edge — the chin end — is cropped")
  func faceAgainstBottomEdgeIsCropped() {
    let cropped = Self.box(x: 0.45, y: 0.0, w: 0.10, h: 0.12)
    #expect(FrameEdgeCrop.isCropped(boundingBox: cropped, margin: 0.01, flagsTopEdge: false))
  }

  /// Headroom cropping is common on laptops and mostly benign, and counting it
  /// would put many users permanently in the warned state — which costs the
  /// ambient pulse's one bit its meaning.
  @Test("Headroom cropping is ignored by default, and honored when asked for")
  func topEdgeIsOptional() {
    let headroom = Self.box(x: 0.45, y: 0.88, w: 0.10, h: 0.12)
    #expect(!FrameEdgeCrop.isCropped(boundingBox: headroom, margin: 0.01, flagsTopEdge: false))
    #expect(FrameEdgeCrop.isCropped(boundingBox: headroom, margin: 0.01, flagsTopEdge: true))
  }

  @Test("A zero margin means only an actual boundary touch counts")
  func zeroMarginIsStrict() {
    let nearlyTouching = Self.box(x: 0.005, y: 0.45, w: 0.10, h: 0.12)
    #expect(!FrameEdgeCrop.isCropped(boundingBox: nearlyTouching, margin: 0, flagsTopEdge: false))
    let touching = Self.box(x: 0.0, y: 0.45, w: 0.10, h: 0.12)
    #expect(FrameEdgeCrop.isCropped(boundingBox: touching, margin: 0, flagsTopEdge: false))
  }

  @Test("A wider margin catches a face merely approaching an edge")
  func marginWidensTheCatch() {
    let approaching = Self.box(x: 0.03, y: 0.45, w: 0.10, h: 0.12)
    #expect(!FrameEdgeCrop.isCropped(boundingBox: approaching, margin: 0.01, flagsTopEdge: false))
    #expect(FrameEdgeCrop.isCropped(boundingBox: approaching, margin: 0.05, flagsTopEdge: false))
  }

  /// Unreadable geometry must not raise a warning: this signal exists to tell
  /// the user something, and one raised on a degenerate box is a false alarm
  /// they can neither act on nor verify.
  @Test("Degenerate and non-finite boxes never report cropped")
  func degenerateBoxesAreNotCropped() {
    #expect(!FrameEdgeCrop.isCropped(boundingBox: .zero, margin: 0.01, flagsTopEdge: false))
    #expect(!FrameEdgeCrop.isCropped(boundingBox: .null, margin: 0.01, flagsTopEdge: false))
    #expect(!FrameEdgeCrop.isCropped(boundingBox: .infinite, margin: 0.01, flagsTopEdge: false))
    let notANumber = CGRect(x: Double.nan, y: 0.4, width: 0.1, height: 0.1)
    #expect(!FrameEdgeCrop.isCropped(boundingBox: notANumber, margin: 0.01, flagsTopEdge: false))
  }

  /// A face filling the frame touches every edge — and that IS partially out
  /// of frame, not a false positive: leaning in far enough to fill the shot
  /// cuts off the sides of your own head.
  @Test("A face filling the frame counts as cropped")
  func fillingFaceIsCropped() {
    let filling = Self.box(x: 0.0, y: 0.0, w: 1.0, h: 1.0)
    #expect(FrameEdgeCrop.isCropped(boundingBox: filling, margin: 0.01, flagsTopEdge: false))
  }
}

/// `PulseStateMachine` — the one bit the ambient pulse carries.
struct PulseStateMachineTests {
  private static func machine() -> PulseStateMachine {
    PulseStateMachine(enterMs: 10000, exitMs: 3000)
  }

  @Test("Starts normal and stays normal while nothing is wrong")
  func startsNormal() {
    var machine = Self.machine()
    #expect(machine.current == .normal)
    #expect(machine.update(isCropped: false, now: 0) == .normal)
    #expect(machine.update(isCropped: false, now: 60) == .normal)
  }

  /// Slow to alarm: "you have been like this for a while," not "you moved."
  @Test("Entering attention requires the full 10s dwell")
  func entryRequiresLongDwell() {
    var machine = Self.machine()
    #expect(machine.update(isCropped: true, now: 0) == .normal)
    #expect(machine.update(isCropped: true, now: 9.5) == .normal)
    #expect(machine.update(isCropped: true, now: 10.0) == .attention)
  }

  /// A person leaning aside to pick something up must never trip it.
  @Test("A brief crop well under the dwell never flips the bit")
  func briefCropIsIgnored() {
    var machine = Self.machine()
    #expect(machine.update(isCropped: true, now: 0) == .normal)
    #expect(machine.update(isCropped: true, now: 4) == .normal)
    #expect(machine.update(isCropped: false, now: 5) == .normal)
    // And the part-served dwell is abandoned, not banked: a second brief crop
    // starting later must serve the full 10s of its own.
    #expect(machine.update(isCropped: true, now: 6) == .normal)
    #expect(machine.update(isCropped: true, now: 14) == .normal)
    #expect(machine.update(isCropped: true, now: 16.5) == .attention)
  }

  /// Prompt to reassure: a user who has just corrected should hear that it
  /// worked without serving out the entry dwell again.
  @Test("Leaving attention takes the shorter 3s dwell")
  func exitIsQuickerThanEntry() {
    var machine = Self.machine()
    _ = machine.update(isCropped: true, now: 0)
    #expect(machine.update(isCropped: true, now: 10) == .attention)
    // The exit dwell is measured from when the condition CHANGED (t=12), not
    // from when attention was entered — so it clears three seconds later.
    #expect(machine.update(isCropped: false, now: 12) == .attention)
    #expect(machine.update(isCropped: false, now: 14) == .attention)
    #expect(machine.update(isCropped: false, now: 15) == .normal)
  }

  @Test("Flapping faster than either dwell never settles into a transition")
  func flappingNeverSettles() {
    var machine = Self.machine()
    var now = 0.0
    for _ in 0..<40 {
      #expect(machine.update(isCropped: true, now: now) == .normal)
      now += 2
      #expect(machine.update(isCropped: false, now: now) == .normal)
      now += 2
    }
  }

  /// A user who walks back may be perfectly placed; greeting them with a stale
  /// warning would be a claim the pulse cannot explain.
  @Test("reset() returns to normal and abandons any part-served dwell")
  func resetClearsEverything() {
    var machine = Self.machine()
    _ = machine.update(isCropped: true, now: 0)
    #expect(machine.update(isCropped: true, now: 10) == .attention)
    machine.reset()
    #expect(machine.current == .normal)
    #expect(machine.update(isCropped: true, now: 11) == .normal)
    #expect(machine.update(isCropped: true, now: 20.5) == .normal)
    #expect(machine.update(isCropped: true, now: 21.5) == .attention)
  }
}
