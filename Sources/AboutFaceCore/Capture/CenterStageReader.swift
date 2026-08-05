import AVFoundation

/// The impure counterpart to `CenterStageReading.swift`'s value types: talks
/// to `AVCaptureDevice` directly, and is therefore only compile-tested, same
/// rationale as `CMIOPropertyReader` (see that type's doc comment) -- CI has
/// no camera hardware, so nothing here can be exercised against a real,
/// Center-Stage-capable device. `CenterStageReadingTests` covers the pure
/// parts (`automaticFramingInEffect`'s truth table,
/// `CenterStageDeviceReading`'s not-confusable-with-off guarantee) with real
/// assertions instead. `controlMode(fromRawValue:)` below is an exception --
/// see its own doc comment for why it is both impure-file-adjacent and
/// genuinely unit-tested.
///
/// **This app never SETS Center Stage state.** `AVCaptureDevice
/// .centerStageControlMode`/`isCenterStageEnabled` both have setters, but
/// calling either would change the user's OWN system-level Center Stage
/// state -- taking control away from their own Control Center toggle -- and
/// the setters throw `NSInvalidArgumentException` outside the matching
/// control mode besides. Every function below only reads.
public enum CenterStageReader {
  /// Reads every Center Stage fact §12.5 asks for off an already-resolved
  /// `AVCaptureDevice` -- the shape `CenterStageAllDevicesReader
  /// .currentSummaries()` needs internally, and the one `read(forUniqueID:)`
  /// below delegates to once it has resolved a device.
  public static func read(device: AVCaptureDevice) -> CenterStageReading {
    CenterStageReading(
      controlMode: controlMode(from: AVCaptureDevice.centerStageControlMode),
      systemEnabled: AVCaptureDevice.isCenterStageEnabled,
      activeFormatSupports: device.activeFormat.isCenterStageSupported,
      anyFormatSupports: device.formats.contains { $0.isCenterStageSupported },
      deviceReportsActive: device.isCenterStageActive)
  }

  /// Resolves `uniqueID` via a fresh `AVCaptureDevice.DiscoverySession`
  /// (never cached -- same "resolved at call time" rationale as
  /// `CMIOPropertyReader.enumerateDeviceHandles()`, since Continuity Camera
  /// devices come and go per §12.1) and reads it, or reports
  /// `.deviceNotFound` if nothing matches. See `CenterStageDeviceReading`'s
  /// doc comment for why resolution failure is its own case rather than a
  /// default `CenterStageReading`.
  ///
  /// `CameraFormatProbe` deliberately calls this (re-resolving by
  /// `uniqueID`) for its before/after-session-open readings, rather than
  /// reading straight off the `AVCaptureDevice` it already holds: a stale
  /// object reference reading `isCenterStageActive` would keep returning
  /// SOME `Bool` even if the device disconnected between the "before" and
  /// "after" reads (a real possibility for a Continuity Camera or external
  /// USB webcam across the multi-second frame-wait `probe(...)` performs),
  /// and a plausible-looking `false` in that situation is exactly the
  /// "worked, but silently uncertain" shape §12.2's finding warns against.
  /// Re-resolving makes that disconnect visible as `.deviceNotFound` instead
  /// of a false "off."
  public static func read(forUniqueID uniqueID: String) -> CenterStageDeviceReading {
    guard let device = resolvedDevice(uniqueID: uniqueID) else { return .deviceNotFound }
    return .found(read(device: device))
  }

  /// §12.5's per-device breakdown: one `CenterStageDeviceSummary` per
  /// enumerable video device, mirroring `CMIOAllDevicesBusyReader
  /// .currentRunningStates()`'s shape (§12.3) so the maintainer can see
  /// which of his cameras is even Center-Stage-capable. Uses the same
  /// device-type list `AVCaptureDeviceProvider.defaultDeviceTypes` does, so
  /// this enumerates exactly the cameras the rest of the app considers
  /// selectable.
  public static func currentSummaries() -> [CenterStageDeviceSummary] {
    discoverySession().devices.map { device in
      CenterStageDeviceSummary(
        deviceUniqueID: device.uniqueID,
        deviceLocalizedName: device.localizedName,
        anyFormatSupports: device.formats.contains { $0.isCenterStageSupported },
        deviceReportsActive: device.isCenterStageActive)
    }
  }

  private static func resolvedDevice(uniqueID: String) -> AVCaptureDevice? {
    discoverySession().devices.first { $0.uniqueID == uniqueID }
  }

  private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: AVCaptureDeviceProvider.defaultDeviceTypes, mediaType: .video,
      position: .unspecified)
  }

  /// Converts AVFoundation's own `CenterStageControlMode` to this codebase's
  /// `Sendable` mirror -- kept here, not in `CenterStageReading.swift`, so
  /// that file needs no `import AVFoundation` at all.
  static func controlMode(
    from mode: AVCaptureDevice.CenterStageControlMode
  ) -> CenterStageControlMode {
    controlMode(fromRawValue: mode.rawValue)
  }

  /// The actual mapping, over the raw `Int` rather than the AVFoundation
  /// enum directly -- deliberately, so it can be unit-tested (see
  /// `CenterStageControlModeMappingTests`) without constructing a synthetic
  /// `AVCaptureDevice.CenterStageControlMode` value. Whether
  /// `init(rawValue:)` on an SDK-imported, non-frozen ObjC enum succeeds for
  /// an undocumented raw value is exactly the kind of SDK/toolchain detail
  /// CLAUDE.md's toolchain-skew note warns against depending on; testing
  /// against a plain `Int` sidesteps the question entirely while still
  /// exercising the real mapping logic. 0/1/2 are `.user`/`.app`/
  /// `.cooperative` per `AVCaptureDevice.h` (verified against the header,
  /// not re-derived here); anything else is `.unknown`.
  static func controlMode(fromRawValue rawValue: Int) -> CenterStageControlMode {
    switch rawValue {
    case 0: return .user
    case 1: return .app
    case 2: return .cooperative
    default: return .unknown(rawValue)
    }
  }
}
