import Testing

@testable import AboutFaceCore

// swift-format and swiftlint disagree on trailing commas in multiline
// collection literals (see `PipelineModel.swift`'s import block for the
// canonical example of this same conflict elsewhere in the codebase);
// swift-format wins per CLAUDE.md, so `trailing_comma` is disabled for this
// whole file's synthetic `[CMIODeviceRunningState]` array literals below.
// swiftlint:disable trailing_comma

/// `CameraMismatchClassifier` (§12.3): the pure per-snapshot classification
/// half of the mismatch warning. No `CoreMediaIO`/`AVFoundation` import, no
/// clock, no previous-call state — every case here is a single `classify`
/// call over a synthetic `[CMIODeviceRunningState]`, so none of it needs a
/// live camera (CI rule). Debounce/dismiss timing lives in
/// `CameraMismatchStateMachineTests` instead.
struct CameraMismatchClassifierTests {
  private let selected = "selected-device"
  private let other = "other-device"
  private let thirdDevice = "third-device"

  // MARK: - The corrected rule: selected device's own reading is ignored

  @Test("Selected device running, every other device idle: clear — self-capture is not evidence")
  func selectedRunningOthersIdle_clear() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .running),
      CMIODeviceRunningState(uniqueID: other, reading: .idle),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("Selected device idle, a non-selected device running: mismatch — the literal §12.3 case")
  func selectedIdleOtherRunning_mismatch() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .idle),
      CMIODeviceRunningState(uniqueID: other, reading: .running),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .mismatch)
  }

  @Test("Selected device also running (About Face capturing) plus another running: still mismatch")
  func selectedRunningAndOtherRunning_stillMismatch() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .running),
      CMIODeviceRunningState(uniqueID: other, reading: .running),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .mismatch)
  }

  @Test("Only the selected device present, running: clear — nothing else to compare against")
  func onlySelectedDevicePresent_clear() {
    let readings = [CMIODeviceRunningState(uniqueID: selected, reading: .running)]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("Multiple non-selected devices, only one running: mismatch")
  func multipleOthers_onlyOneRunning_mismatch() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .idle),
      CMIODeviceRunningState(uniqueID: other, reading: .idle),
      CMIODeviceRunningState(uniqueID: thirdDevice, reading: .running),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .mismatch)
  }

  // MARK: - `nil` selection: nothing to compare against

  @Test("No camera selected: always clear, regardless of what else is running")
  func nilSelection_alwaysClear() {
    let readings = [
      CMIODeviceRunningState(uniqueID: other, reading: .running),
      CMIODeviceRunningState(uniqueID: thirdDevice, reading: .running),
    ]
    #expect(CameraMismatchClassifier.classify(selectedUniqueID: nil, readings: readings) == .clear)
  }

  // MARK: - Failed reads: "not running" for comparison, but not silently "all clear"

  @Test("A non-selected device that failed to read is treated as not running, not as mismatch")
  func nonSelectedFailedRead_treatedAsNotRunning() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .idle),
      CMIODeviceRunningState(uniqueID: other, reading: .propertyReadFailed(-1)),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("A non-selected device reading .deviceNotFound is treated as not running too")
  func nonSelectedDeviceNotFound_treatedAsNotRunning() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .idle),
      CMIODeviceRunningState(uniqueID: other, reading: .deviceNotFound),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("Every device failing to read is .unreliable, not .clear")
  func everyDeviceFailed_unreliable() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .propertyReadFailed(-1)),
      CMIODeviceRunningState(uniqueID: other, reading: .deviceNotFound),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .unreliable)
  }

  @Test("An empty snapshot (enumeration itself found nothing) is .unreliable, not .clear")
  func emptySnapshot_unreliable() {
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: []) == .unreliable)
  }

  @Test("One device failed to read among others that read fine: real evidence wins, not unreliable")
  func oneFailedAmongReadable_notUnreliable() {
    let readings = [
      CMIODeviceRunningState(uniqueID: selected, reading: .idle),
      CMIODeviceRunningState(uniqueID: other, reading: .propertyReadFailed(-1)),
      CMIODeviceRunningState(uniqueID: thirdDevice, reading: .idle),
    ]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("Only the selected device present and its read failed: unreliable — nothing was readable")
  func onlySelectedPresentAndFailed_unreliable() {
    let readings = [CMIODeviceRunningState(uniqueID: selected, reading: .propertyReadFailed(-1))]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .unreliable)
  }

  // MARK: - Selected device absent from the snapshot entirely

  @Test("Selected device not present at all, a non-selected device idle: clear")
  func selectedAbsent_otherIdle_clear() {
    let readings = [CMIODeviceRunningState(uniqueID: other, reading: .idle)]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings) == .clear)
  }

  @Test("Selected device not present at all, a non-selected device running: mismatch")
  func selectedAbsent_otherRunning_mismatch() {
    let readings = [CMIODeviceRunningState(uniqueID: other, reading: .running)]
    #expect(
      CameraMismatchClassifier.classify(selectedUniqueID: selected, readings: readings)
        == .mismatch)
  }
}
// swiftlint:enable trailing_comma
