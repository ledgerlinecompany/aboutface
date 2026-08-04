import Testing

@testable import AboutFaceCore

/// `CMIODeviceLookup.match` (§12.2's "map `AVCaptureDevice.uniqueID` to a
/// `CMIOObjectID`... verify the match rather than assuming ordering"): the
/// one piece of the CMIO busy-signal feature that is pure and therefore
/// genuinely unit-testable with synthetic data, no CoreMediaIO call and no
/// hardware involved (CI rule: no test may require a live camera). Everything
/// else this PR adds that actually talks to CoreMediaIO is compile-only
/// tested — see `CameraProbeCompileOnlyTests`.
struct CMIODeviceLookupTests {
  // swift-format requires trailing commas in multiline collection literals;
  // swiftlint's default forbids them. Same documented conflict as
  // ConfigStore.swift; format wins.
  // swiftlint:disable trailing_comma

  @Test("Matches the handle whose uid equals the requested uniqueID")
  func matchesExactUID() {
    let handles = [
      CMIODeviceHandle(objectID: 1, uid: "built-in-camera"),
      CMIODeviceHandle(objectID: 2, uid: "continuity-camera"),
      CMIODeviceHandle(objectID: 3, uid: "desk-view-camera"),
    ]
    #expect(CMIODeviceLookup.match(uniqueID: "continuity-camera", in: handles) == 2)
  }

  @Test("Does not assume ordering -- matches by uid even when the target isn't first")
  func matchIsNotPositional() {
    let handles = [
      CMIODeviceHandle(objectID: 10, uid: "some-other-device"),
      CMIODeviceHandle(objectID: 20, uid: "some-other-device-2"),
      CMIODeviceHandle(objectID: 30, uid: "the-selected-device"),
    ]
    #expect(CMIODeviceLookup.match(uniqueID: "the-selected-device", in: handles) == 30)
  }

  @Test("Returns nil when no handle's uid matches")
  func noMatchReturnsNil() {
    let handles = [
      CMIODeviceHandle(objectID: 1, uid: "some-device"),
      CMIODeviceHandle(objectID: 2, uid: "another-device"),
    ]
    #expect(CMIODeviceLookup.match(uniqueID: "nonexistent-device-for-testing", in: handles) == nil)
  }
  // swiftlint:enable trailing_comma

  @Test("Returns nil against an empty device list")
  func emptyListReturnsNil() {
    #expect(CMIODeviceLookup.match(uniqueID: "anything", in: []) == nil)
  }

  @Test("Comparison is exact -- no case-folding or substring matching")
  func matchIsExactNotFuzzy() {
    let handles = [CMIODeviceHandle(objectID: 1, uid: "Built-In-Camera")]
    #expect(CMIODeviceLookup.match(uniqueID: "built-in-camera", in: handles) == nil)
    #expect(CMIODeviceLookup.match(uniqueID: "Built-In-Camera", in: handles) == 1)
  }
}
