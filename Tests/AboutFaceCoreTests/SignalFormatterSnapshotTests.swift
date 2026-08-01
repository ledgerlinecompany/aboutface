import CoreGraphics
import Testing

@testable import AboutFaceCore

/// Integration tests for `SignalFormatter.snapshot(...)` (spec §9):
/// placeholder text ("never blank, never stale-looking"), full-field
/// coverage in the fixed §9 order, and an end-to-end "real values across
/// the board" check. Split out of `SignalFormatterTests.swift` purely to
/// stay under SwiftLint's per-type length limit; shared fixture builders
/// live in `SignalFormatterTestSupport.swift`.
struct SignalFormatterSnapshotTests {

  @Test("snapshot(): nil output shows 'Not started' for every measured field")
  func snapshot_nilOutput_showsNotStarted() {
    let rows = SignalFormatter.snapshot(
      output: nil, backendName: "Apple Vision", captureFormat: nil, mirrorState: nil)

    let byField = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
    #expect(byField[.headroom] == "Not started")
    #expect(byField[.horizontalOffset] == "Not started")
    #expect(byField[.faceCount] == "Not started")
    #expect(byField[.backendName] == "Apple Vision")  // static field, always available
    #expect(byField[.captureFormat] == "Not started")
    #expect(byField[.mirrorState] == "Not started")
  }

  @Test("snapshot(): noFace state shows 'No face detected' for face-dependent fields")
  func snapshot_noFace_showsNoFacePlaceholder() {
    let engineOutput = formatterTestOutput(
      signalState: .noFace, faceCount: 0, primary: nil, lighting: formatterTestLighting(),
      framing: nil)
    let rows = SignalFormatter.snapshot(
      output: engineOutput, backendName: "Apple Vision",
      captureFormat: .init(width: 1280, height: 720, frameRate: 30), mirrorState: .notMirrored)

    let byField = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
    #expect(byField[.headroom] == "No face detected")
    #expect(byField[.horizontalOffset] == "No face detected")
    #expect(byField[.faceBox] == "No face detected")
    #expect(byField[.yaw] == "No face detected")
    #expect(byField[.faceCount] == "0 faces detected")  // whole-frame field: still real
    #expect(byField[.backgroundLuma] == "50%")  // whole-frame field: still real
  }

  @Test("snapshot(): noSignal state shows 'No signal' for face-dependent fields")
  func snapshot_noSignal_showsNoSignalPlaceholder() {
    let engineOutput = formatterTestOutput(
      signalState: .noSignal, faceCount: 0, primary: nil, lighting: formatterTestLighting(),
      framing: nil)
    let rows = SignalFormatter.snapshot(
      output: engineOutput, backendName: "Apple Vision", captureFormat: nil, mirrorState: nil)

    let byField = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
    #expect(byField[.headroom] == "No signal")
    #expect(byField[.interocularDistance] == "No signal")
  }

  @Test("snapshot(): full field coverage, one row per Field case, fixed order")
  func snapshot_coversEveryField() {
    let rows = SignalFormatter.snapshot(
      output: nil, backendName: "Apple Vision", captureFormat: nil, mirrorState: nil)
    #expect(rows.map(\.id) == SignalFormatter.Field.allCases)
    #expect(rows.allSatisfy { !$0.label.isEmpty && !$0.value.isEmpty })
  }

  @Test("snapshot(): ok state with a face reports real values across the board")
  func snapshot_okState_reportsRealValues() {
    let engineOutput = formatterTestOutput(
      signalState: .ok,
      faceCount: 1,
      primary: formatterTestGeometry(
        eyeMidpoint: CGPoint(x: 0.5, y: 0.62), yaw: 10, pitch: -5, roll: 2),
      lighting: formatterTestLighting(faceLuma: 0.6, backgroundLuma: 0.4, backlightDelta: -0.2),
      framing: formatterTestFraming(errorX: -0.05, distanceError: 0.01))

    let rows = SignalFormatter.snapshot(
      output: engineOutput, backendName: "Apple Vision",
      captureFormat: .init(width: 1280, height: 720, frameRate: 30), mirrorState: .notMirrored)
    let byField = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })

    #expect(byField[.headroom] == "38%")
    #expect(byField[.horizontalOffset] == "5% left of target")
    #expect(byField[.faceLuma] == "60%")
    #expect(byField[.backlightDelta] == "20 points brighter face")
    #expect(byField[.yaw] == "+10.0° (turned toward own right)")
    #expect(byField[.pitch] == "-5.0° (chin down)")
    #expect(byField[.roll] == "+2.0° (tilted toward own right)")
    #expect(byField[.backendConfidence] == "95%")
    #expect(byField[.captureFormat] == "1280×720 @ 30fps")
    #expect(byField[.mirrorState] == "Not mirrored")
  }
}
