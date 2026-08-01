import CoreGraphics
import Foundation

/// The per-field formatting functions and shared numeric primitives behind
/// every §9 row. Split out of `SignalFormatter.swift` purely to keep each
/// file a manageable size (see that file's doc comment); everything here is
/// still `SignalFormatter`'s own implementation, not a separate public
/// surface. These are exactly the functions `SignalFormatterTests.swift`
/// exercises directly with hand-derived expected values.
extension SignalFormatter {

  // MARK: - Per-field formatting

  /// Headroom (§9): percent of frame above the eye midpoint.
  /// `FaceGeometry.eyeMidpoint.y` is normalized, BOTTOM-LEFT origin (§3.3,
  /// `VisionBackend`'s coordinate contract, `AnalysisEngine+Framing.swift`),
  /// so the fraction of frame ABOVE the eyes is `1 - y`.
  static func formatHeadroom(_ geometry: FaceGeometry) -> String {
    let headroomFraction = 1 - Float(geometry.eyeMidpoint.y)
    return percentString(headroomFraction)
  }

  /// Horizontal offset (§9), with direction word (§3.4 egocentric):
  /// `FramingState.error.x > 0` means "the subject is right of target"
  /// (§3.3's own doc comment on `FramingState.error`), so a positive error
  /// reads "N% right of target" and a negative error reads "N% left of
  /// target" — never "the subject should move," since this is a read-only
  /// state value, not an instruction (§9 vs. §6.3's instruction phrasing
  /// are deliberately different registers).
  static func formatHorizontalOffset(_ framing: FramingState) -> String {
    let percent = Int((abs(framing.error.x) * 100).rounded())
    guard percent != 0 else { return "On target" }
    let direction = framing.error.x > 0 ? "right" : "left"
    return "\(percent)% \(direction) of target"
  }

  /// Face box origin and size (§9), normalized, 2 decimals.
  static func formatFaceBox(_ geometry: FaceGeometry) -> String {
    let box = geometry.boundingBox
    let origin =
      "(\(fixed(box.origin.x, decimals: 2)), \(fixed(box.origin.y, decimals: 2)))"
    let size =
      "\(fixed(box.width, decimals: 2)) × \(fixed(box.height, decimals: 2))"
    return "origin \(origin), size \(size)"
  }

  /// Interocular distance (§9) plus the §4 target-relative distance
  /// phrasing. `FramingState.distanceError` is documented "+ = too close"
  /// (§3.3), so a positive value reads "closer than target" and a negative
  /// value reads "farther than target." A small epsilon absorbs
  /// floating-point noise around exactly-on-target so that value doesn't
  /// flicker between "closer"/"farther" for a value that is, for display
  /// purposes, zero — this is a display-rounding constant, not a §0/§11
  /// engine threshold (it changes no behavior, only which word is printed).
  static func formatInterocularDistance(_ geometry: FaceGeometry, framing: FramingState) -> String {
    let distance = fixed(geometry.interocularDistance, decimals: 2)
    let epsilon: Float = 0.0005
    let phrase: String
    if framing.distanceError > epsilon {
      phrase = "closer than target"
    } else if framing.distanceError < -epsilon {
      phrase = "farther than target"
    } else {
      phrase = "at target distance"
    }
    return "\(distance) (\(phrase))"
  }

  /// Backlight delta (§9): `backgroundLuma - faceLuma` (§3.3), "high =
  /// backlit." Reported as signed percentage points plus the same word the
  /// spec's own field doc uses ("backlit") so the reading is self-
  /// explanatory without cross-referencing another row.
  static func formatBacklightDelta(_ delta: Float) -> String {
    let points = Int((delta * 100).rounded())
    if points > 0 {
      return "\(points) points brighter background (backlit)"
    } else if points < 0 {
      return "\(abs(points)) points brighter face"
    } else {
      return "Even (0 points)"
    }
  }

  /// Yaw (§9): degrees, signed, one decimal, egocentric. `FaceGeometry.yaw`
  /// is documented "+ = subject's head turned to their right" (§3.3).
  static func formatYaw(_ yaw: Float) -> String {
    guard yaw != 0 else { return "0.0° (facing camera)" }
    let direction = yaw > 0 ? "own right" : "own left"
    return "\(signedDegrees(yaw))° (turned toward \(direction))"
  }

  /// Pitch (§9): `FaceGeometry.pitch` is "+ = chin up" (§3.3).
  static func formatPitch(_ pitch: Float) -> String {
    guard pitch != 0 else { return "0.0° (level)" }
    let direction = pitch > 0 ? "chin up" : "chin down"
    return "\(signedDegrees(pitch))° (\(direction))"
  }

  /// Roll (§9): `FaceGeometry.roll` is "+ = subject's head tilted to their
  /// right" (§3.3).
  static func formatRoll(_ roll: Float) -> String {
    guard roll != 0 else { return "0.0° (level)" }
    let direction = roll > 0 ? "own right" : "own left"
    return "\(signedDegrees(roll))° (tilted toward \(direction))"
  }

  static func formatFaceCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "face" : "faces") detected"
  }

  static func formatCaptureFormat(_ descriptor: CaptureFormatDescriptor) -> String {
    let fps: String
    if descriptor.frameRate.rounded() == descriptor.frameRate {
      fps = String(Int(descriptor.frameRate))
    } else {
      fps = fixed(descriptor.frameRate, decimals: 1)
    }
    return "\(descriptor.width)×\(descriptor.height) @ \(fps)fps"
  }

  static func formatMirrorState(_ mirrorState: MirrorState) -> String {
    switch mirrorState {
    case .mirrored: return "Mirrored"
    case .notMirrored: return "Not mirrored"
    }
  }

  // MARK: - Numeric primitives

  /// Formats a `0...1`-ish fraction as a whole-number percent. Not clamped
  /// — a value that legitimately exceeds `0...1` (measurement noise, an
  /// out-of-range metric) still prints rather than silently clipping to a
  /// misleading 100%.
  static func percentString(_ fraction: Float) -> String {
    "\(Int((fraction * 100).rounded()))%"
  }

  static func signedDegrees(_ value: Float) -> String {
    let magnitude = fixed(Double(abs(value)), decimals: 1)
    return value > 0 ? "+\(magnitude)" : "-\(magnitude)"
  }

  static func fixed(_ value: Double, decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
  }

  static func fixed(_ value: CGFloat, decimals: Int) -> String {
    fixed(Double(value), decimals: decimals)
  }
}
