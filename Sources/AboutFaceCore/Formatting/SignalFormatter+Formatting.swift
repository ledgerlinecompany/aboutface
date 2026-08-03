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
  static func formatHeadroom(_ geometry: FaceGeometry, display: Config.Display) -> String {
    let headroomFraction = 1 - Float(geometry.eyeMidpoint.y)
    return percentString(headroomFraction, display: display)
  }

  /// Horizontal offset (§9), with direction word (§3.4 egocentric):
  /// `FramingState.error.x > 0` means "the subject is right of target"
  /// (§3.3's own doc comment on `FramingState.error`), so a positive error
  /// reads "N% right of target" and a negative error reads "N% left of
  /// target" — never "the subject should move," since this is a read-only
  /// state value, not an instruction (§9 vs. §6.3's instruction phrasing
  /// are deliberately different registers).
  static func formatHorizontalOffset(_ framing: FramingState, display: Config.Display) -> String {
    // Quantize BEFORE the zero/direction decision so noise around the
    // target reads as a stable "On target" rather than flickering between
    // "1% left" and "1% right".
    let percent = quantizedPercent(abs(framing.error.x), display: display)
    guard percent != 0 else { return "On target" }
    let direction = framing.error.x > 0 ? "right" : "left"
    return "\(percent)% \(direction) of target"
  }

  /// Face box origin and size (§9), normalized, 2 decimals.
  static func formatFaceBox(_ geometry: FaceGeometry, display: Config.Display) -> String {
    let box = geometry.boundingBox
    func q(_ value: CGFloat) -> String {
      fixed(quantized(Double(value), step: display.normalizedStep), decimals: 2)
    }
    let origin = "(\(q(box.origin.x)), \(q(box.origin.y)))"
    let size = "\(q(box.width)) × \(q(box.height))"
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
  static func formatInterocularDistance(
    _ geometry: FaceGeometry, framing: FramingState, display: Config.Display
  ) -> String {
    let distance = fixed(
      quantized(Double(geometry.interocularDistance), step: display.normalizedStep), decimals: 2)
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
  static func formatBacklightDelta(_ delta: Float, display: Config.Display) -> String {
    let points =
      delta > 0
      ? quantizedPercent(delta, display: display)
      : -quantizedPercent(-delta, display: display)
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
  static func formatYaw(_ yaw: Float, display: Config.Display) -> String {
    let degrees = quantizedDegrees(yaw, display: display)
    guard degrees != 0 else { return "0° (facing camera)" }
    let direction = degrees > 0 ? "own right" : "own left"
    // Unsigned magnitude: the direction word carries the sign. "−4° toward
    // own left" read as a double negative in the Phase 2 VO pass.
    return "\(abs(degrees))° toward \(direction)"
  }

  /// Pitch (§9): `FaceGeometry.pitch` is "+ = chin up" (§3.3).
  static func formatPitch(_ pitch: Float, display: Config.Display) -> String {
    let degrees = quantizedDegrees(pitch, display: display)
    guard degrees != 0 else { return "0° (level)" }
    let direction = degrees > 0 ? "chin up" : "chin down"
    return "\(abs(degrees))° \(direction)"
  }

  /// Roll (§9): `FaceGeometry.roll` is "+ = subject's head tilted to their
  /// right" (§3.3).
  static func formatRoll(_ roll: Float, display: Config.Display) -> String {
    let degrees = quantizedDegrees(roll, display: display)
    guard degrees != 0 else { return "0° (level)" }
    let direction = degrees > 0 ? "own right" : "own left"
    return "\(abs(degrees))° tilted toward \(direction)"
  }

  static func formatFaceCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "face" : "faces") detected"
  }

  /// Renders the REQUESTED capture format, and — the §9 point of this
  /// function's `actual` parameter — flags it explicitly when the camera's
  /// ACTUAL delivered dimensions (`actual`, from a real
  /// `CapturedFrame.pixelDimensions`) disagree. `actual` defaults to `nil`
  /// (matching behavior before this existed: just the request) for callers
  /// that only have the request, or that haven't seen a frame yet.
  ///
  /// Deliberately factual, not corrective: this never "fixes" `descriptor`
  /// to match `actual`, and says nothing when they agree beyond the plain
  /// requested string — a mismatch is exactly the signal PR #53 showed a
  /// maintainer needs (a requested format silently NOT taking effect), and
  /// silently reporting the request as if it were confirmed truth would
  /// reproduce that same failure one layer up.
  static func formatCaptureFormat(
    _ descriptor: CaptureFormatDescriptor, actual: PixelDimensions? = nil
  ) -> String {
    let fps: String
    if descriptor.frameRate.rounded() == descriptor.frameRate {
      fps = String(Int(descriptor.frameRate))
    } else {
      fps = fixed(descriptor.frameRate, decimals: 1)
    }
    let requested = "\(descriptor.width)×\(descriptor.height) @ \(fps)fps"
    guard let actual, actual.width != descriptor.width || actual.height != descriptor.height else {
      return requested
    }
    return "\(requested), camera actually delivered \(actual.width)×\(actual.height)"
  }

  static func formatMirrorState(_ mirrorState: MirrorState) -> String {
    switch mirrorState {
    case .mirrored: return "Mirrored"
    case .notMirrored: return "Not mirrored"
    }
  }

  // MARK: - Numeric primitives

  /// Formats a `0...1`-ish fraction as a percent quantized to
  /// `display.percentStep` (§9 Phase 2 acceptance feedback: raw signals
  /// jitter at the last digit; VoiceOver users need coarse stable steps).
  /// Not clamped — a value that legitimately exceeds `0...1` (measurement
  /// noise, an out-of-range metric) still prints rather than silently
  /// clipping to a misleading 100%.
  static func percentString(_ fraction: Float, display: Config.Display) -> String {
    "\(quantizedPercent(fraction, display: display))%"
  }

  /// Fraction → whole percent rounded to the nearest `percentStep`.
  static func quantizedPercent(_ fraction: Float, display: Config.Display) -> Int {
    let step = max(display.percentStep, 1)
    return Int((Double(fraction) * 100 / step).rounded() * step)
  }

  /// Degrees rounded to the nearest `degreesStep`, as a whole number.
  static func quantizedDegrees(_ value: Float, display: Config.Display) -> Int {
    let step = max(display.degreesStep, 1)
    return Int((Double(value) / step).rounded() * step)
  }

  /// Rounds a value to the nearest multiple of `step` (display only —
  /// never used in engine decisions).
  static func quantized(_ value: Double, step: Double) -> Double {
    guard step > 0 else { return value }
    return (value / step).rounded() * step
  }

  static func fixed(_ value: Double, decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
  }

  static func fixed(_ value: CGFloat, decimals: Int) -> String {
    fixed(Double(value), decimals: decimals)
  }
}
