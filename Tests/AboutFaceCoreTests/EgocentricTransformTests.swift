import CoreGraphics
import Testing

@testable import AboutFaceCore

/// Covers the spec §3.4 MUST-have test directly: "a corpus clip where the
/// subject is unambiguously to their own left produces `error.x < 0` and the
/// instruction 'right', under both mirrored and unmirrored capture
/// configuration."
///
/// Hand-derived expectations (see `EgocentricTransform`'s doc comment for the
/// full reasoning):
///
/// - Unmirrored (raw sensor image): the subject's own right maps to *low*
///   raw image X (they appear on the image's left, as if facing you); their
///   own left maps to *high* raw image X. So `egocentricX = 1 - imageX`.
/// - Mirrored: the flip already happened in hardware, so raw image X already
///   matches egocentric sense directly: `egocentricX = imageX`.
///
/// A subject standing to their own left, physically in the same spot,
/// therefore produces:
/// - Unmirrored raw image X ≈ 0.8 (high — appears on the right of the raw
///   frame) → egocentric X = 1 - 0.8 = 0.2.
/// - Mirrored raw image X ≈ 0.2 (low — appears on the left of the mirrored
///   frame, matching a real mirror) → egocentric X = 0.2.
///
/// Both configurations must agree: egocentric X = 0.2, which is less than a
/// centered target (0.5), giving `error.x = 0.2 - 0.5 = -0.3 < 0`, which is
/// exactly the "instruction: right" case per `FramingState.error`'s "+ =
/// subject is right of target" convention (§3.3).
/// Floating-point tolerance for comparisons involving arithmetic (e.g.
/// `1 - x`), which are not guaranteed to round-trip to the exact same bit
/// pattern as a literal of the mathematically expected value.
private let epsilon: CGFloat = 1e-9

private func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool {
  abs(a - b) < epsilon
}

struct EgocentricTransformTests {

  // MARK: - Subject to their own left (the spec's required test case)

  @Test("Subject to their own left: unmirrored raw X 0.8 -> egocentric 0.2")
  func subjectOwnLeft_unmirrored() {
    let result = EgocentricTransform.egocentricX(imageX: 0.8, mirror: .notMirrored)
    #expect(approxEqual(result, 0.2))
  }

  @Test("Subject to their own left: mirrored raw X 0.2 -> egocentric 0.2")
  func subjectOwnLeft_mirrored() {
    let result = EgocentricTransform.egocentricX(imageX: 0.2, mirror: .mirrored)
    #expect(approxEqual(result, 0.2))
  }

  @Test(
    "Subject to their own left agrees across mirror states, and yields error.x < 0 / instruction right"
  )
  func subjectOwnLeft_agreesAcrossMirrorStates_andProducesNegativeError() {
    let unmirroredX = EgocentricTransform.egocentricX(imageX: 0.8, mirror: .notMirrored)
    let mirroredX = EgocentricTransform.egocentricX(imageX: 0.2, mirror: .mirrored)

    #expect(approxEqual(unmirroredX, mirroredX))

    let target: CGFloat = 0.50  // Config.defaults.targetFraming.eyeMidpointX
    let errorUnmirrored = unmirroredX - target
    let errorMirrored = mirroredX - target

    #expect(errorUnmirrored < 0)  // "instruction: right"
    #expect(errorMirrored < 0)  // "instruction: right"
    #expect(approxEqual(errorUnmirrored, errorMirrored))
  }

  // MARK: - Subject to their own right (symmetric case)

  @Test("Subject to their own right: unmirrored raw X 0.2 -> egocentric 0.8")
  func subjectOwnRight_unmirrored() {
    let result = EgocentricTransform.egocentricX(imageX: 0.2, mirror: .notMirrored)
    #expect(approxEqual(result, 0.8))
  }

  @Test("Subject to their own right: mirrored raw X 0.8 -> egocentric 0.8")
  func subjectOwnRight_mirrored() {
    let result = EgocentricTransform.egocentricX(imageX: 0.8, mirror: .mirrored)
    #expect(approxEqual(result, 0.8))
  }

  @Test(
    "Subject to their own right agrees across mirror states, and yields error.x > 0 / instruction left"
  )
  func subjectOwnRight_agreesAcrossMirrorStates_andProducesPositiveError() {
    let unmirroredX = EgocentricTransform.egocentricX(imageX: 0.2, mirror: .notMirrored)
    let mirroredX = EgocentricTransform.egocentricX(imageX: 0.8, mirror: .mirrored)

    #expect(approxEqual(unmirroredX, mirroredX))

    let target: CGFloat = 0.50
    #expect(unmirroredX - target > 0)  // "instruction: left"
    #expect(mirroredX - target > 0)  // "instruction: left"
  }

  // MARK: - Centered subject: mirror state must not matter

  @Test("Centered subject: both mirror states agree on egocentric center")
  func centeredSubject_agreesAcrossMirrorStates() {
    let unmirroredX = EgocentricTransform.egocentricX(imageX: 0.5, mirror: .notMirrored)
    let mirroredX = EgocentricTransform.egocentricX(imageX: 0.5, mirror: .mirrored)

    #expect(unmirroredX == 0.5)
    #expect(mirroredX == 0.5)
  }

  // MARK: - Edge extremes

  @Test("Edge extremes map correctly for both mirror states")
  func edgeExtremes() {
    #expect(EgocentricTransform.egocentricX(imageX: 0.0, mirror: .notMirrored) == 1.0)
    #expect(EgocentricTransform.egocentricX(imageX: 1.0, mirror: .notMirrored) == 0.0)
    #expect(EgocentricTransform.egocentricX(imageX: 0.0, mirror: .mirrored) == 0.0)
    #expect(EgocentricTransform.egocentricX(imageX: 1.0, mirror: .mirrored) == 1.0)
  }

  // MARK: - Point variant

  @Test("egocentricPoint flips X only, leaves Y untouched")
  func egocentricPoint_flipsXOnly() {
    let point = CGPoint(x: 0.8, y: 0.3)

    let unmirrored = EgocentricTransform.egocentricPoint(point, mirror: .notMirrored)
    #expect(approxEqual(unmirrored.x, 0.2))
    #expect(unmirrored.y == 0.3)

    let mirrored = EgocentricTransform.egocentricPoint(point, mirror: .mirrored)
    #expect(mirrored.x == 0.8)
    #expect(mirrored.y == 0.3)
  }

  // MARK: - Rect variant

  @Test("egocentricRect passes through unchanged when mirrored")
  func egocentricRect_mirroredIsIdentity() {
    let rect = CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3)
    let result = EgocentricTransform.egocentricRect(rect, mirror: .mirrored)
    #expect(result == rect)
  }

  @Test("egocentricRect flips horizontally when unmirrored, preserving width/height")
  func egocentricRect_unmirroredFlips() {
    // A face box in the raw unmirrored image at x: [0.6, 0.8] (minX 0.6, width 0.2).
    // Flipping: newMinX = 1 - maxX = 1 - 0.8 = 0.2.
    let rect = CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3)
    let result = EgocentricTransform.egocentricRect(rect, mirror: .notMirrored)

    #expect(approxEqual(result.origin.x, 0.2))
    #expect(result.origin.y == 0.2)
    #expect(result.width == 0.2)
    #expect(result.height == 0.3)
  }
}
