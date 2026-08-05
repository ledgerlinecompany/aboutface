import Testing

@testable import AboutFaceCore

/// `CenterStageReading.automaticFramingInEffect`'s truth table, and
/// `CenterStageDeviceReading`'s not-confusable-with-off guarantee -- both
/// pure and therefore genuinely unit-testable with real assertions, no
/// camera hardware involved. The impure reader (`CenterStageReader`, which
/// actually talks to `AVCaptureDevice`) is only compile-tested, same
/// convention as `CMIOPropertyReader` -- see `CameraProbeCompileOnlyTests`.
struct CenterStageReadingTests {
  private static func reading(
    controlMode: CenterStageControlMode = .user,
    systemEnabled: Bool,
    activeFormatSupports: Bool,
    anyFormatSupports: Bool,
    deviceReportsActive: Bool
  ) -> CenterStageReading {
    CenterStageReading(
      controlMode: controlMode,
      systemEnabled: systemEnabled,
      activeFormatSupports: activeFormatSupports,
      anyFormatSupports: anyFormatSupports,
      deviceReportsActive: deviceReportsActive)
  }

  @Test("automaticFramingInEffect is true when the device reports active, full stop")
  func trueWhenDeviceReportsActive() {
    let value = Self.reading(
      systemEnabled: true, activeFormatSupports: true, anyFormatSupports: true,
      deviceReportsActive: true)
    #expect(value.automaticFramingInEffect)
  }

  @Test("systemEnabled true does NOT count as automatic framing on its own")
  func systemEnabledAloneIsNotAutomatic() {
    let value = Self.reading(
      systemEnabled: true, activeFormatSupports: true, anyFormatSupports: true,
      deviceReportsActive: false)
    #expect(!value.automaticFramingInEffect)
  }

  @Test("An unsupported active format does NOT count as automatic framing")
  func unsupportedActiveFormatIsNotAutomatic() {
    let value = Self.reading(
      systemEnabled: true, activeFormatSupports: false, anyFormatSupports: true,
      deviceReportsActive: false)
    #expect(!value.automaticFramingInEffect)
  }

  @Test("Enabled but on a device that supports no format is not automatic")
  func enabledUnsupportedDeviceIsNotAutomatic() {
    let value = Self.reading(
      systemEnabled: true, activeFormatSupports: false, anyFormatSupports: false,
      deviceReportsActive: false)
    #expect(!value.automaticFramingInEffect)
  }

  @Test("automaticFramingInEffect is false when everything is off")
  func falseWhenEverythingOff() {
    let value = Self.reading(
      systemEnabled: false, activeFormatSupports: false, anyFormatSupports: false,
      deviceReportsActive: false)
    #expect(!value.automaticFramingInEffect)
  }

  @Test("deviceReportsActive alone is authoritative, even against systemEnabled == false")
  func deviceReportsActiveOverridesSystemEnabledFalse() {
    // Not expected in ordinary operation, but the type makes no assumption
    // that systemEnabled and deviceReportsActive can't disagree, and
    // automaticFramingInEffect's contract is "deviceReportsActive and
    // nothing else" -- this pins that contract even in a combination that
    // shouldn't arise in practice.
    let value = Self.reading(
      systemEnabled: false, activeFormatSupports: true, anyFormatSupports: true,
      deviceReportsActive: true)
    #expect(value.automaticFramingInEffect)
  }
}

/// `CenterStageReader.controlMode(fromRawValue:)`'s AVFoundation-raw-value
/// mapping. Tested over a plain `Int`, not a constructed
/// `AVCaptureDevice.CenterStageControlMode`, deliberately -- see that
/// function's doc comment for why depending on `init(rawValue:)`'s behavior
/// for an undocumented raw value would itself be an SDK/toolchain
/// assumption CLAUDE.md's toolchain-skew note warns against.
struct CenterStageControlModeMappingTests {
  @Test("Maps the documented raw values 0/1/2 to .user/.app/.cooperative")
  func mapsKnownRawValues() {
    #expect(CenterStageReader.controlMode(fromRawValue: 0) == .user)
    #expect(CenterStageReader.controlMode(fromRawValue: 1) == .app)
    #expect(CenterStageReader.controlMode(fromRawValue: 2) == .cooperative)
  }

  @Test("An unrecognized raw value round-trips to .unknown, not a guessed case")
  func unknownRawValueRoundTrips() {
    // 99 is not a control mode any shipped SDK defines -- this simulates a
    // future OS adding a fourth mode this file predates.
    #expect(CenterStageReader.controlMode(fromRawValue: 99) == .unknown(99))
  }
}

/// `CenterStageDeviceReading.deviceNotFound` -- structurally distinct from
/// any `.found` value, and specifically not equal to a `.found` reading
/// where everything happens to read "off." This is the type-safety
/// guarantee §12.5's read layer exists to provide -- see
/// `CenterStageDeviceReading`'s doc comment.
struct CenterStageDeviceReadingTests {
  @Test("deviceNotFound is not equal to a .found reading where everything is off")
  func deviceNotFoundIsNotConfusableWithOff() {
    let everythingOff = CenterStageReading(
      controlMode: .user, systemEnabled: false, activeFormatSupports: false,
      anyFormatSupports: false, deviceReportsActive: false)
    #expect(CenterStageDeviceReading.deviceNotFound != .found(everythingOff))
  }

  @Test("deviceNotFound equals itself -- sanity check on Equatable")
  func deviceNotFoundEqualsItself() {
    #expect(CenterStageDeviceReading.deviceNotFound == .deviceNotFound)
  }
}
