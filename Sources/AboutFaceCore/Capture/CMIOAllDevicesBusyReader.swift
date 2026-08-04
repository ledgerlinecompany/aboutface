/// One CMIO device's running-somewhere reading, keyed by the persistent
/// `AVCaptureDevice.uniqueID`-equivalent UID (see `CMIODeviceLookup`'s doc
/// comment for that identification assumption) rather than by the
/// process-local `CMIOObjectID` — this is meant to be compared against
/// `Config.Camera.selectedCameraID` and other `AVCaptureDevice.uniqueID`
/// values, which never see a raw `CMIOObjectID`.
public struct CMIODeviceRunningState: Sendable, Equatable {
  public let uniqueID: String
  public let reading: CMIORunningSomewhereReading

  public init(uniqueID: String, reading: CMIORunningSomewhereReading) {
    self.uniqueID = uniqueID
    self.reading = reading
  }
}

/// §12.3's cross-device query: "is some device OTHER than the selected one
/// running" needs a running-state reading for every camera, not just the
/// selected one. This type exposes exactly that reading, one
/// `CMIODeviceRunningState` per enumerable device — nothing else. It
/// deliberately does NOT compare against a selected device or decide
/// whether a mismatch warning should fire; §12.3 explicitly separates
/// "designing and building the replacement [heuristic]" from having a
/// working per-device signal to build it on, and this type is only the
/// latter. The `probe-camera` CLI is, for now, this type's only consumer —
/// see `ProbeCameraCommand.swift`.
public enum CMIOAllDevicesBusyReader {
  /// One `CMIOPropertyReader.enumerateDeviceHandles()` call plus one
  /// `CMIOPropertyReader.runningSomewhere(_:)` read per handle. Impure
  /// (talks to CoreMediaIO) and therefore only compile-tested, same as
  /// everything else in `CMIOPropertyReader.swift` — see that file's
  /// type-level doc comment.
  public static func currentRunningStates() -> [CMIODeviceRunningState] {
    CMIOPropertyReader.enumerateDeviceHandles().map { handle in
      CMIODeviceRunningState(
        uniqueID: handle.uid, reading: CMIOPropertyReader.runningSomewhere(handle.objectID))
    }
  }
}
