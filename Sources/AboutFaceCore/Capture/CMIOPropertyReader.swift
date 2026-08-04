import CoreMediaIO
import Foundation

/// One CoreMediaIO device as CMIOObjectSystemObject's device list reports
/// it: its `CMIOObjectID` (an opaque handle, meaningful only within this
/// process's current CoreMediaIO session — never persisted or compared
/// across relaunches) paired with the device's own
/// `kCMIODevicePropertyDeviceUID` reading.
///
/// This is the raw material `CMIODeviceLookup.match(uniqueID:in:)` matches
/// against, kept as a tiny `Sendable` value type (`CMIOObjectID` is a
/// `UInt32`, so both fields are trivially `Sendable`) so that matching logic
/// can be unit-tested against synthetic arrays with no CoreMediaIO call
/// involved — the "device-ID matching logic" the PR brief asks to test
/// without hardware.
public struct CMIODeviceHandle: Sendable, Equatable {
  public let objectID: CMIOObjectID
  public let uid: String

  public init(objectID: CMIOObjectID, uid: String) {
    self.objectID = objectID
    self.uid = uid
  }
}

/// The non-lossy answer to "is this CMIO device running somewhere" — as
/// opposed to `CameraBusyProvider.currentValue()`'s `Bool`, which the
/// protocol fixes at `Bool` for every conformance and which therefore
/// CANNOT distinguish "device found and idle" from "no device matched at
/// all." Collapsing those two into the same `false` is exactly what §12.2's
/// finding warns against repeating: `isInUseByAnotherApplication` reading
/// `false` while a call was genuinely live was discovered by comparing
/// against a second, independent signal, not by `isInUseByAnotherApplication`
/// itself ever admitting uncertainty. This type is that second signal's own
/// admission of uncertainty, made explicit instead of swallowed.
///
/// See `CMIOCameraBusyProvider`'s type-level doc comment for exactly how its
/// `currentValue()` (protocol-mandated `Bool`) and `currentReading()` (this
/// type, not part of the protocol) relate.
public enum CMIORunningSomewhereReading: Sendable, Equatable {
  /// The device was found and `kCMIODevicePropertyDeviceIsRunningSomewhere`
  /// reads nonzero: some process — possibly this one — is streaming from it.
  /// See that constant's §12.2 finding for the "any process, including us"
  /// asymmetry this implies.
  case running
  /// The device was found and the property reads zero: nothing is streaming
  /// from it anywhere.
  case idle
  /// No CMIO device's `kCMIODevicePropertyDeviceUID` matched the requested
  /// `AVCaptureDevice.uniqueID`. Deliberately distinct from `.idle` — see
  /// this type's doc comment.
  case deviceNotFound
  /// The device was found, but the property read itself failed with a
  /// genuine CoreMediaIO error — distinct from "not found." Carries the raw
  /// `OSStatus` for diagnostics; not expected in ordinary operation.
  case propertyReadFailed(OSStatus)
}

/// Raw CoreMediaIO property reads backing §12.2's replacement busy signal:
/// `kCMIODevicePropertyDeviceIsRunningSomewhere`, global scope, main
/// element — the exact selector/scope/element §12.2's finding measured
/// against a live Zoom call. Modeled on `/tmp/cmio-reference-probe.swift`'s
/// throwaway experiment for API *shape* only (device enumeration via
/// `kCMIOHardwarePropertyDevices` on `kCMIOObjectSystemObject`, then a UID
/// read per device) — NOT for its error handling, which that file's own
/// header comment disclaims ("Not repo code... has no [error handling]
/// worth keeping"). Every call here is instead checked against `noErr` and
/// turned into a typed outcome rather than silently treated as "empty" or
/// "unreadable."
///
/// Every function below is impure — it talks to CoreMediaIO — and therefore
/// only compile-tested (CI rule: no test may require a live camera; see
/// `CameraProbeCompileOnlyTests`). The one piece of this feature's logic
/// that IS behaviorally tested with real assertions is
/// `CMIODeviceLookup.match`, deliberately split into its own file as a pure
/// function over `[CMIODeviceHandle]` rather than being inlined here, so it
/// can be exercised with synthetic data.
public enum CMIOPropertyReader {
  /// Enumerates every device CoreMediaIO currently knows about (cameras;
  /// CoreMediaIO does not expose audio devices — CoreAudio owns those) and
  /// reads each one's persistent UID. Fresh every call, never cached — same
  /// "resolved at call time, not cached" rationale as
  /// `AVCaptureDeviceBusyProvider.resolveDevice()`, since CMIO's device list
  /// can change (a Continuity Camera connecting/disconnecting) just like
  /// `AVCaptureDevice.DiscoverySession`'s can. A device whose UID can't be
  /// read is skipped rather than surfaced as a handle with a placeholder
  /// UID, since a handle that can never match anything is useless to
  /// `CMIODeviceLookup.match`.
  public static func enumerateDeviceHandles() -> [CMIODeviceHandle] {
    deviceObjectIDs().compactMap { objectID in
      guard let uid = deviceUID(objectID) else { return nil }
      return CMIODeviceHandle(objectID: objectID, uid: uid)
    }
  }

  /// Reads `kCMIODevicePropertyDeviceIsRunningSomewhere` for an
  /// already-resolved `CMIOObjectID`.
  public static func runningSomewhere(_ objectID: CMIOObjectID) -> CMIORunningSomewhereReading {
    var address = runningSomewhereAddress
    var size: UInt32 = 0
    var status = CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr, size > 0 else { return .propertyReadFailed(status) }

    var running: UInt32 = 0
    var used: UInt32 = 0
    status = CMIOObjectGetPropertyData(objectID, &address, 0, nil, size, &used, &running)
    guard status == noErr else { return .propertyReadFailed(status) }
    return running != 0 ? .running : .idle
  }

  /// Convenience combining `enumerateDeviceHandles()` +
  /// `CMIODeviceLookup.match` + `runningSomewhere(_:)` — the single call
  /// both `CMIOCameraBusyProvider` (§12.2) and `CameraFormatProbe`'s CMIO
  /// reporting (§12.6's `probe-camera`) need, kept in exactly one place so
  /// the two call sites can't drift apart on how resolution failure is
  /// handled.
  public static func runningSomewhere(forUniqueID uniqueID: String) -> CMIORunningSomewhereReading {
    guard
      let objectID = CMIODeviceLookup.match(
        uniqueID: uniqueID, in: enumerateDeviceHandles())
    else {
      return .deviceNotFound
    }
    return runningSomewhere(objectID)
  }

  /// `kCMIODevicePropertyDeviceIsRunningSomewhere`'s address — a `var`
  /// computed property (not a stored `let`) because
  /// `CMIOObjectGetPropertyDataSize`/`GetPropertyData` take
  /// `UnsafePointer<CMIOObjectPropertyAddress>`, which requires an
  /// addressable (mutable) local at each call site; a shared stored
  /// constant would still need copying into a local `var` at every use, so
  /// this just does that once, here.
  private static var runningSomewhereAddress: CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
  }

  private static func deviceObjectIDs() -> [CMIOObjectID] {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }

    let count = Int(size) / MemoryLayout<CMIOObjectID>.size
    var ids = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, size, &used, &ids) == noErr
    else { return [] }
    return ids
  }

  /// `kCMIODevicePropertyDeviceUID` is documented as a `CFString` the
  /// caller is responsible for releasing — i.e. a +1-owned reference, not a
  /// borrowed one. `Unmanaged<CFString>.takeRetainedValue()` is the correct
  /// way to hand that +1 to ARC exactly once; binding straight to a
  /// `CFString?` local (as the throwaway reference probe does) would leave
  /// that +1 unbalanced.
  private static func deviceUID(_ objectID: CMIOObjectID) -> String? {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0
    else { return nil }

    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(objectID, &address, 0, nil, size, &used, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
  }
}
