import Testing

@testable import AboutFaceCore

/// `CenterStageClassifier` (§12.5's app-side wiring): the pure per-reading
/// classification half. No `AVFoundation` import, no clock, no
/// previous-call state — every case here is a single `classify` call over a
/// synthetic `CenterStageDeviceReading`, so none of it needs a live camera
/// (CI rule). Debounce/`isEnabled` timing lives in
/// `CenterStageStateMachineTests` instead.
struct CenterStageClassifierTests {
  private static func reading(deviceReportsActive: Bool) -> CenterStageReading {
    CenterStageReading(
      controlMode: .user, systemEnabled: false, activeFormatSupports: true,
      anyFormatSupports: true, deviceReportsActive: deviceReportsActive)
  }

  @Test("A found reading with automaticFramingInEffect true classifies as .active")
  func found_active_classifiesActive() {
    let value = CenterStageDeviceReading.found(Self.reading(deviceReportsActive: true))
    #expect(CenterStageClassifier.classify(value) == .active)
  }

  @Test("A found reading with automaticFramingInEffect false classifies as .notActive")
  func found_notActive_classifiesNotActive() {
    let value = CenterStageDeviceReading.found(Self.reading(deviceReportsActive: false))
    #expect(CenterStageClassifier.classify(value) == .notActive)
  }

  @Test("deviceNotFound classifies as .unknown, never .notActive — the critical design point")
  func deviceNotFound_classifiesUnknown() {
    #expect(CenterStageClassifier.classify(.deviceNotFound) == .unknown)
  }
}
