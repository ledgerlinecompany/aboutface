/// §12.5's read layer: this app's own mirror of
/// `AVCaptureDevice.CenterStageControlMode` (`.user`/`.app`/`.cooperative`),
/// kept as a value distinct from AVFoundation's own type per CLAUDE.md's
/// toolchain-skew rule -- no AVFoundation/Vision type may cross an
/// isolation boundary on the strength of the SDK's own `Sendable`
/// annotation, so `CenterStageReading` (below) stores this mirror instead
/// of the framework enum directly.
///
/// `.unknown(Int)` exists so a future OS revision that adds a fourth
/// control mode is reported honestly -- as a value nothing in this codebase
/// has an opinion about yet -- rather than silently coerced onto
/// `.user`/`.app`/`.cooperative`, which would misrepresent what the OS
/// actually reported. See `CenterStageReader.controlMode(from:)` (in
/// `CenterStageReader.swift`, the impure sibling of this file) for where
/// the conversion from AVFoundation's enum happens -- kept there, not here,
/// so this file needs no `import AVFoundation` at all.
public enum CenterStageControlMode: Sendable, Equatable {
  /// Only the user's own Control Center toggle sets Center Stage state.
  /// This is `AVCaptureDevice.centerStageControlMode`'s documented default.
  case user
  /// Only this process itself may set Center Stage state. Not applicable to
  /// About Face in practice -- see `CenterStageReading`'s doc comment: this
  /// app never sets any Center Stage property, in any control mode.
  case app
  /// Both the user and the app may set Center Stage state.
  case cooperative
  /// A raw `AVCaptureCenterStageControlMode` value this file's author did
  /// not know about at the time it was written. Carries the raw value for
  /// diagnostics. See this type's doc comment for why this case exists
  /// instead of guessing which known case it is "probably" closest to.
  case unknown(Int)
}

/// One moment's Center Stage facts for one `AVCaptureDevice`, plus the pure
/// classification over them (`automaticFramingInEffect`, below). §12.5's
/// read layer: this is a read-only observation. Nothing in this PR, and
/// nothing that should ever be built on top of it, may call the setter side
/// of `centerStageControlMode`/`isCenterStageEnabled` -- doing so would
/// change the user's OWN system-level Center Stage state, taking control
/// away from their own Control Center toggle, and the setters throw
/// `NSInvalidArgumentException` outside the matching control mode besides.
/// See `CenterStageReader`'s doc comment for where the (read-only) SDK
/// calls actually happen.
///
/// ## The correction this type records
///
/// §12.5's own spec text calls Center Stage "a per-capture-session
/// setting." Per `AVCaptureDevice.h`, that is not quite right:
/// `centerStageControlMode` and `isCenterStageEnabled` are **class**
/// properties -- process-wide, not per session, and in practice driven by
/// the user's own systemwide Control Center toggle (default
/// `centerStageControlMode == .user`). What actually varies per
/// device/configuration is `isCenterStageActive` (an **instance**
/// property): per the header, "a particular AVCaptureDevice instance may
/// return YES for this property, depending whether it supports the feature
/// in its current configuration." The practical consequence is the same or
/// worse than the original text implied: this process can observe whether
/// Center Stage is active on the capture WE hold, and cannot observe a
/// conferencing app's capture session at all -- see
/// `automaticFramingInEffect`'s doc comment and the known limitation there.
public struct CenterStageReading: Sendable, Equatable {
  /// `AVCaptureDevice.centerStageControlMode` -- process-wide, not
  /// per-device: every `CenterStageReading` taken at the same instant, for
  /// any device, reports the same value here.
  public let controlMode: CenterStageControlMode
  /// `AVCaptureDevice.isCenterStageEnabled` -- process-wide, reflecting the
  /// user's own Control Center toggle in `.user`/`.cooperative` mode. Per
  /// the header, "may change at any time." See `automaticFramingInEffect`'s
  /// doc comment for why this field alone must never be read as "framing is
  /// automatic."
  public let systemEnabled: Bool
  /// `device.activeFormat.isCenterStageSupported` -- whether the format
  /// this device is CURRENTLY configured to use supports Center Stage.
  public let activeFormatSupports: Bool
  /// Whether ANY format this device offers supports Center Stage --
  /// broader than `activeFormatSupports`, so "this device can never do
  /// Center Stage" can be told apart from "this device could, just not in
  /// its current configuration."
  public let anyFormatSupports: Bool
  /// `device.isCenterStageActive` -- instance-level, read-only. The one
  /// field `automaticFramingInEffect` actually trusts; see that property's
  /// doc comment.
  public let deviceReportsActive: Bool

  public init(
    controlMode: CenterStageControlMode,
    systemEnabled: Bool,
    activeFormatSupports: Bool,
    anyFormatSupports: Bool,
    deviceReportsActive: Bool
  ) {
    self.controlMode = controlMode
    self.systemEnabled = systemEnabled
    self.activeFormatSupports = activeFormatSupports
    self.anyFormatSupports = anyFormatSupports
    self.deviceReportsActive = deviceReportsActive
  }

  /// Whether Center Stage is, right now, actually auto-framing the subject
  /// on THIS device -- and therefore, once a later PR builds product
  /// behavior on top of this reading, whether About Face's own framing
  /// feedback would be redundant. This is **`deviceReportsActive` and
  /// nothing else.**
  ///
  /// ## Why not `systemEnabled`
  ///
  /// `systemEnabled` is tempting -- it is the more visible of the two
  /// signals, the Control Center toggle -- but it is process-wide, and
  /// "enabled, yet doing nothing" is a real, ordinary state: an unsupported
  /// device, or a device whose CURRENT format doesn't support Center Stage
  /// (`activeFormatSupports == false`) even though some other format on it
  /// would. Treating `systemEnabled == true` as "framing is automatic"
  /// would suppress About Face's core framing signal on hardware where
  /// Center Stage is doing nothing at all -- going silent about framing on
  /// exactly the camera that most needs About Face's feedback.
  ///
  /// ## Which direction is safe to be wrong in
  ///
  /// Same reasoning §12.4 applies to virtual-camera name matching, restated
  /// for this signal: this property can be wrong in two directions, and
  /// they are not equally bad. Under-detecting (reporting `false` when
  /// Center Stage is in fact framing the subject) means About Face keeps
  /// giving framing feedback that might be redundant -- a nuisance the user
  /// notices almost immediately, not a hazard. Over-detecting (reporting
  /// `true` when nothing is auto-framing) means About Face goes silent
  /// about framing on a camera where no one is correcting it -- exactly the
  /// failure this section's own text names as worse: "silently reporting a
  /// framing problem the OS is already correcting is worse than reporting
  /// nothing," and by the same logic, silently NOT reporting a framing
  /// problem that nothing is correcting is worse still.
  /// `deviceReportsActive` is Apple's own instance-level answer to "is this
  /// happening on this device, right now, in its current configuration" --
  /// the narrowest, most literal signal available, and therefore the one
  /// least likely to claim automatic framing where none is happening.
  /// `systemEnabled`/`controlMode`/`activeFormatSupports`/
  /// `anyFormatSupports` remain on this type because they are genuinely
  /// useful diagnostic context (`probe-camera` prints all five), but none
  /// of them factor into this computed property.
  ///
  /// ## Known and permanent limitation
  ///
  /// A conferencing app's own capture session can have Center Stage active
  /// while About Face's does not, or the reverse -- two different capture
  /// sessions on the same physical device can independently negotiate
  /// different active formats, and `isCenterStageActive` only ever answers
  /// for the instance it is read on. Nothing in this process can observe
  /// another process's capture session. Same posture as §12.4's
  /// known-and-permanent name-list gap: there is no more reliable signal
  /// available, so this is recorded here rather than worked around.
  public var automaticFramingInEffect: Bool {
    deviceReportsActive
  }
}

/// §12.5's central structural requirement: a device that cannot be resolved
/// must NOT be representable as "Center Stage off." A plain
/// `CenterStageReading` with every field `false`/`.user` would be
/// bit-for-bit identical to "this device is real, and Center Stage is
/// genuinely off on it" -- the exact shape of the failures this project has
/// already shipped and had to un-ship (see
/// `CMIORunningSomewhereReading.deviceNotFound`'s doc comment for the same
/// argument made about a different signal). So resolution failure is its
/// own case here, not a default value a caller could mistake for a real
/// reading.
public enum CenterStageDeviceReading: Sendable, Equatable {
  /// The device was found and read successfully.
  case found(CenterStageReading)
  /// No device matched the requested `AVCaptureDevice.uniqueID`.
  /// Deliberately not equal to, and not convertible to, any `.found` value
  /// -- see this type's doc comment.
  case deviceNotFound
}

/// One device's Center Stage capability/state summary, for the per-device
/// breakdown §12.5 asks `probe-camera` to print -- mirrors
/// `CMIODeviceRunningState`'s per-device shape (§12.3), so the maintainer
/// can identify which of his cameras is even Center-Stage-capable before
/// any product behavior is built on top of that fact. Deliberately a
/// narrower summary than the full `CenterStageReading`: `controlMode` and
/// `systemEnabled` are process-wide (see `CenterStageReading`'s doc
/// comment), so repeating them once per device would just print the same
/// two values over and over -- this type omits them, and `probe-camera`
/// prints them once, up front, instead.
public struct CenterStageDeviceSummary: Sendable, Equatable {
  public let deviceUniqueID: String
  public let deviceLocalizedName: String
  /// Whether ANY format this device offers supports Center Stage -- see
  /// `CenterStageReading.anyFormatSupports`.
  public let anyFormatSupports: Bool
  /// `device.isCenterStageActive`, read at enumeration time -- see
  /// `CenterStageReading.deviceReportsActive`.
  public let deviceReportsActive: Bool

  public init(
    deviceUniqueID: String,
    deviceLocalizedName: String,
    anyFormatSupports: Bool,
    deviceReportsActive: Bool
  ) {
    self.deviceUniqueID = deviceUniqueID
    self.deviceLocalizedName = deviceLocalizedName
    self.anyFormatSupports = anyFormatSupports
    self.deviceReportsActive = deviceReportsActive
  }
}
