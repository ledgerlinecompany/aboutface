import CoreGraphics

/// Converts backend-native normalized coordinates into egocentric
/// coordinates, per spec §3.4. This is the one place in the codebase where
/// `MirrorState` changes a coordinate value — everything before this point is
/// "raw image space," everything after is "egocentric," and no other file
/// should need to reason about mirroring again.
///
/// ## Reasoning (read before touching this file)
///
/// A front-facing camera faces the subject, so its raw (unmirrored) image is
/// like looking at another person: the subject's own right hand appears on
/// the *left* side of the frame, exactly as it would if someone stood facing
/// you and raised their right hand — it appears on your left. So:
///
/// - **Unmirrored** (`isVideoMirrored == false`, raw sensor image): the
///   subject's own right maps to *low* raw image X (left side of frame); the
///   subject's own left maps to *high* raw image X (right side of frame).
///   This is the spec's own framing of the case: "the subject visibly on the
///   left side of an unmirrored image is on their own right."
///
/// - **Mirrored** (`isVideoMirrored == true`): the raw image is flipped
///   horizontally before delivery specifically so the preview behaves like a
///   physical mirror — raising your real right hand makes the reflection's
///   hand appear on the right side of *your* view, because a mirror you are
///   looking straight into does not swap left/right the way facing another
///   person does. So in a mirrored image, the subject's own right maps to
///   *high* raw image X, and their own left maps to *low* raw image X.
///
/// Egocentric X is defined so that **increasing X = further toward the
/// subject's own right** (consistent with `FramingState.error.x`'s "+ =
/// subject is right of target," §3.3). Given the above:
///
/// - Unmirrored: egocentric X = `1 - imageX` (flip).
/// - Mirrored: egocentric X = `imageX` (identity — the mirror flip already
///   happened in hardware/AVFoundation, undoing the facing-flip).
///
/// The critical invariant this buys us, and what
/// `EgocentricTransformTests` checks directly: the **same physical
/// position** of the subject produces the **same egocentric X** regardless of
/// `MirrorState`. A subject standing to their own left produces a low
/// egocentric X — and therefore `error.x < 0` against a centered target, and
/// the instruction "right" — whether or not the capture happens to be
/// mirrored. Getting this backwards is the single worst failure mode this
/// project has (§3.4); it must not depend on which mirror configuration a
/// given camera/OS happens to hand back.
///
/// Vertical position is unaffected by horizontal mirroring, so Y passes
/// through unchanged here. (Backend-native Y-origin conventions, e.g.
/// Vision's bottom-left vs. a hypothetical top-left backend, are a separate,
/// per-backend normalization concern — not something `MirrorState` encodes —
/// and are out of scope for this pure transform.)
public enum EgocentricTransform {
  /// Converts a single backend-native normalized X coordinate to egocentric
  /// X, per the reasoning documented on this type.
  ///
  /// - Parameters:
  ///   - imageX: Normalized X in the backend's raw, native image space
  ///     (0 = left edge of the delivered image, 1 = right edge), as it
  ///     appears in the frame actually delivered for the given
  ///     `MirrorState` (i.e. already reflecting any hardware/AVFoundation
  ///     mirroring — this function does not re-apply that flip, it converts
  ///     from "image space" to "egocentric space").
  ///   - mirror: The capture session's mirror configuration for this frame.
  /// - Returns: Egocentric X where increasing value = further toward the
  ///   subject's own right.
  public static func egocentricX(imageX: CGFloat, mirror: MirrorState) -> CGFloat {
    switch mirror {
    case .mirrored:
      return imageX
    case .notMirrored:
      return 1 - imageX
    }
  }

  /// Converts a backend-native normalized point to egocentric coordinates.
  /// Only X is affected by mirroring; Y passes through unchanged.
  public static func egocentricPoint(_ point: CGPoint, mirror: MirrorState) -> CGPoint {
    CGPoint(x: egocentricX(imageX: point.x, mirror: mirror), y: point.y)
  }

  /// Converts a backend-native normalized rect to egocentric coordinates.
  ///
  /// For the unmirrored (flip) case, flipping horizontally swaps which edge
  /// is the rect's minimum X: the new `minX` is `1 - maxX` of the original.
  /// Width and height are unaffected; only the rect's horizontal position
  /// changes.
  public static func egocentricRect(_ rect: CGRect, mirror: MirrorState) -> CGRect {
    switch mirror {
    case .mirrored:
      return rect
    case .notMirrored:
      let newOriginX = 1 - rect.origin.x - rect.width
      return CGRect(x: newOriginX, y: rect.origin.y, width: rect.width, height: rect.height)
    }
  }
}
