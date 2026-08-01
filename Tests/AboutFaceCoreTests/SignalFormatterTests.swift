import CoreGraphics
import Testing

@testable import AboutFaceCore

/// Unit tests for `SignalFormatter`'s per-field formatting functions (spec
/// §9): hand-derived expected strings for every field, plus the
/// direction-word sign tests both left and right of target — the one thing
/// this file exists to get exactly right, per §3.4's "get it right and test
/// it." `snapshot()`-level integration tests (placeholders, full-field
/// coverage, end-to-end formatting) live in `SignalFormatterSnapshotTests.swift`
/// — split out purely to stay under SwiftLint's per-type length limit;
/// shared fixture builders live in `SignalFormatterTestSupport.swift`.
struct SignalFormatterTests {

  // MARK: - Horizontal offset direction words (the load-bearing test, §3.4)

  @Test("Horizontal offset: error.x > 0 reads 'right of target'")
  func horizontalOffset_positiveError_readsRight() {
    // FramingState.error.x > 0 means "subject is right of target" per §3.3's
    // doc comment on FramingState.error. 0.12 -> "12% right of target".
    let value = SignalFormatter.formatHorizontalOffset(formatterTestFraming(errorX: 0.12))
    #expect(value == "12% right of target")
  }

  @Test("Horizontal offset: error.x < 0 reads 'left of target'")
  func horizontalOffset_negativeError_readsLeft() {
    let value = SignalFormatter.formatHorizontalOffset(formatterTestFraming(errorX: -0.12))
    #expect(value == "12% left of target")
  }

  @Test("Horizontal offset: error.x == 0 reads 'On target'")
  func horizontalOffset_zeroError_readsOnTarget() {
    let value = SignalFormatter.formatHorizontalOffset(formatterTestFraming(errorX: 0))
    #expect(value == "On target")
  }

  @Test("Horizontal offset rounds to nearest whole percent")
  func horizontalOffset_rounds() {
    // 0.065 -> 6.5% -> rounds to 7% (`.rounded()` uses round-half-away-from-zero).
    let value = SignalFormatter.formatHorizontalOffset(formatterTestFraming(errorX: 0.065))
    #expect(value == "7% right of target")
  }

  @Test("Horizontal offset: small nonzero error still rounds to 0% but is not literally on target")
  func horizontalOffset_tinyError_roundsToZeroPercent() {
    // 0.002 -> 0.2% -> rounds to 0, which reads the same as exactly on
    // target; this is a deliberate display simplification (§9 cares about
    // "sensible value," not sub-percent noise).
    let value = SignalFormatter.formatHorizontalOffset(formatterTestFraming(errorX: 0.002))
    #expect(value == "On target")
  }

  // MARK: - Headroom

  @Test("Headroom: eyeMidpoint.y is bottom-left-origin, headroom% = (1-y)*100")
  func headroom_computedFromBottomLeftOriginY() {
    // y = 0.62 (62% up from bottom) -> headroom = 1 - 0.62 = 0.38 -> 38%.
    let value = SignalFormatter.formatHeadroom(
      formatterTestGeometry(eyeMidpoint: CGPoint(x: 0.5, y: 0.62)))
    #expect(value == "38%")
  }

  @Test("Headroom: eyes at very top of frame (y=1) means 0% headroom")
  func headroom_eyesAtTop() {
    let value = SignalFormatter.formatHeadroom(
      formatterTestGeometry(eyeMidpoint: CGPoint(x: 0.5, y: 1.0)))
    #expect(value == "0%")
  }

  @Test("Headroom: eyes at very bottom of frame (y=0) means 100% headroom")
  func headroom_eyesAtBottom() {
    let value = SignalFormatter.formatHeadroom(
      formatterTestGeometry(eyeMidpoint: CGPoint(x: 0.5, y: 0.0)))
    #expect(value == "100%")
  }

  // MARK: - Face box

  @Test("Face box formats origin and size to 2 decimals")
  func faceBox_formatsToTwoDecimals() {
    let value = SignalFormatter.formatFaceBox(
      formatterTestGeometry(boundingBox: CGRect(x: 0.401, y: 0.456, width: 0.198, height: 0.302)))
    #expect(value == "origin (0.40, 0.46), size 0.20 × 0.30")
  }

  // MARK: - Interocular distance / target-relative phrasing (§4)

  @Test("Interocular distance: distanceError > 0 reads 'closer than target'")
  func interocularDistance_positiveDistanceError_readsCloser() {
    let value = SignalFormatter.formatInterocularDistance(
      formatterTestGeometry(interocularDistance: 0.15),
      framing: formatterTestFraming(distanceError: 0.04))
    #expect(value == "0.15 (closer than target)")
  }

  @Test("Interocular distance: distanceError < 0 reads 'farther than target'")
  func interocularDistance_negativeDistanceError_readsFarther() {
    let value = SignalFormatter.formatInterocularDistance(
      formatterTestGeometry(interocularDistance: 0.07),
      framing: formatterTestFraming(distanceError: -0.04))
    #expect(value == "0.07 (farther than target)")
  }

  @Test("Interocular distance: distanceError ~= 0 reads 'at target distance'")
  func interocularDistance_zeroDistanceError_readsAtTarget() {
    let value = SignalFormatter.formatInterocularDistance(
      formatterTestGeometry(interocularDistance: 0.11),
      framing: formatterTestFraming(distanceError: 0))
    #expect(value == "0.11 (at target distance)")
  }

  // MARK: - Lighting

  @Test("Face/background luma format as whole-number percent")
  func luma_formatsAsPercent() {
    #expect(SignalFormatter.percentString(0.5) == "50%")
    #expect(SignalFormatter.percentString(0.973) == "97%")
    #expect(SignalFormatter.percentString(0) == "0%")
  }

  @Test("Backlight delta: positive delta reads 'brighter background (backlit)'")
  func backlightDelta_positive_readsBacklit() {
    let value = SignalFormatter.formatBacklightDelta(0.18)
    #expect(value == "18 points brighter background (backlit)")
  }

  @Test("Backlight delta: negative delta reads 'brighter face'")
  func backlightDelta_negative_readsFaceBrighter() {
    let value = SignalFormatter.formatBacklightDelta(-0.12)
    #expect(value == "12 points brighter face")
  }

  @Test("Backlight delta: zero reads 'Even'")
  func backlightDelta_zero_readsEven() {
    let value = SignalFormatter.formatBacklightDelta(0)
    #expect(value == "Even (0 points)")
  }

  // MARK: - Pose (yaw / pitch / roll) — §3.3 egocentric sign conventions

  @Test("Yaw: positive reads 'turned toward own right' (§3.3)")
  func yaw_positive_readsOwnRight() {
    #expect(SignalFormatter.formatYaw(12.34) == "+12.3° (turned toward own right)")
  }

  @Test("Yaw: negative reads 'turned toward own left'")
  func yaw_negative_readsOwnLeft() {
    #expect(SignalFormatter.formatYaw(-8.0) == "-8.0° (turned toward own left)")
  }

  @Test("Yaw: exactly zero reads 'facing camera'")
  func yaw_zero_readsFacingCamera() {
    #expect(SignalFormatter.formatYaw(0) == "0.0° (facing camera)")
  }

  @Test("Pitch: positive reads 'chin up' (§3.3)")
  func pitch_positive_readsChinUp() {
    #expect(SignalFormatter.formatPitch(5.6) == "+5.6° (chin up)")
  }

  @Test("Pitch: negative reads 'chin down'")
  func pitch_negative_readsChinDown() {
    #expect(SignalFormatter.formatPitch(-5.6) == "-5.6° (chin down)")
  }

  @Test("Roll: positive reads 'tilted toward own right' (§3.3)")
  func roll_positive_readsOwnRight() {
    #expect(SignalFormatter.formatRoll(3.2) == "+3.2° (tilted toward own right)")
  }

  @Test("Roll: negative reads 'tilted toward own left'")
  func roll_negative_readsOwnLeft() {
    #expect(SignalFormatter.formatRoll(-3.2) == "-3.2° (tilted toward own left)")
  }

  // MARK: - Face count / capture format / mirror state

  @Test("Face count pluralizes correctly")
  func faceCount_pluralizes() {
    #expect(SignalFormatter.formatFaceCount(0) == "0 faces detected")
    #expect(SignalFormatter.formatFaceCount(1) == "1 face detected")
    #expect(SignalFormatter.formatFaceCount(3) == "3 faces detected")
  }

  @Test("Capture format renders integral frame rate without decimal")
  func captureFormat_integralFrameRate() {
    let value = SignalFormatter.formatCaptureFormat(
      .init(width: 1280, height: 720, frameRate: 30))
    #expect(value == "1280×720 @ 30fps")
  }

  @Test("Capture format renders fractional frame rate with one decimal")
  func captureFormat_fractionalFrameRate() {
    let value = SignalFormatter.formatCaptureFormat(
      .init(width: 640, height: 480, frameRate: 14.985))
    #expect(value == "640×480 @ 15.0fps")
  }

  @Test("Mirror state renders both cases")
  func mirrorState_rendersBothCases() {
    #expect(SignalFormatter.formatMirrorState(.mirrored) == "Mirrored")
    #expect(SignalFormatter.formatMirrorState(.notMirrored) == "Not mirrored")
  }
}
