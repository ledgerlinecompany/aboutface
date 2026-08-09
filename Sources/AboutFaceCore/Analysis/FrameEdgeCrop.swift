import CoreGraphics

/// Whether the tracked face is **cropped by the frame edge** — Phase 4.5's
/// "partially out of frame" signal (`docs/design/phase-4.5-app-design.md`
/// §3.3), and the thing §7.4's `.partiallyOutOfFrame` rung has been waiting
/// for since Phase 3.
///
/// ## The distinction that made this hard
///
/// `FeedbackRouter+Condition.swift`'s own note named the obstacle: *"`FaceGeometry`
/// doesn't currently distinguish 'small/far away' from 'cropped by the frame
/// edge'."* Both produce a small bounding box, because Vision clips the box to
/// the frame — a face half out of shot and a face sitting far back look
/// similarly small.
///
/// What separates them is not size but **position**: a cropped face's box is
/// pressed against an edge, and a distant face's box floats with room on every
/// side. So the test is proximity to the boundary, not extent.
///
/// ## Why the top edge is excluded by default
///
/// Headroom cropping — the top of the head trimmed — is extremely common in
/// ordinary laptop use, where the camera sits low and close, and it is mostly
/// benign: the face itself is fully visible and the far end sees a normal
/// picture. A cut-off chin or a face sliding off the side is the actionable
/// case.
///
/// This matters more than it looks, because of what consumes this signal. It
/// drives one bit of an ambient pulse the user hears for hours (design doc
/// §3.3.1), and *"the bar must stay high enough that 'not fine' is rare and
/// means it; a pulse that sits in 'not fine' all afternoon is one the user
/// stops hearing."* Counting headroom would put many users permanently in the
/// warned state, which costs the bit its meaning.
///
/// §4's vertical framing error already covers headroom as a framing
/// preference, on a channel the user can ask about. `flagsTopEdge` exists so
/// this can be revisited by ear (§0) rather than being a decision baked into
/// code.
public enum FrameEdgeCrop {
  /// Whether `boundingBox` — normalized and egocentric, per
  /// `FaceGeometry.boundingBox` — is pressed against a frame edge closely
  /// enough to count as cropped.
  ///
  /// Coordinates are the unit square. A box is "against" an edge when it
  /// comes within `margin` of it; `margin` of zero therefore means "only when
  /// it actually reaches the boundary," which is the strictest reading and a
  /// legitimate configuration.
  ///
  /// Degenerate boxes (empty, or non-finite, which a backend under stress can
  /// produce) return `false`. That direction is deliberate: this signal exists
  /// to raise a warning, and a warning raised on unreadable geometry is a
  /// false alarm the user cannot act on or verify.
  public static func isCropped(
    boundingBox: CGRect, margin: Double, flagsTopEdge: Bool
  ) -> Bool {
    guard !boundingBox.isNull, !boundingBox.isInfinite, !boundingBox.isEmpty else { return false }
    let values = [
      boundingBox.minX, boundingBox.maxX, boundingBox.minY, boundingBox.maxY,
    ]  // swiftlint:disable:previous trailing_comma
    guard values.allSatisfy({ $0.isFinite }) else { return false }
    guard boundingBox.width > 0, boundingBox.height > 0 else { return false }

    let margin = max(0, margin)
    if boundingBox.minX <= margin { return true }
    if boundingBox.maxX >= 1 - margin { return true }
    // `minY` is the BOTTOM edge in the normalized, y-up convention Vision and
    // `FaceGeometry` use — the chin end, which is the case worth catching.
    if boundingBox.minY <= margin { return true }
    if flagsTopEdge, boundingBox.maxY >= 1 - margin { return true }
    return false
  }
}
