import CoreMediaIO

/// Maps an `AVCaptureDevice.uniqueID` to the matching `CMIOObjectID`, per
/// the PR brief: "verify the match rather than assuming ordering." Pure —
/// makes no CoreMediaIO or AVFoundation *calls* (the `CoreMediaIO` import
/// above is only for the `CMIOObjectID`/`CMIOObjectPropertyAddress`
/// typealiases, both plain numeric types) — and operates only on the
/// already-fetched `[CMIODeviceHandle]` `CMIOPropertyReader
/// .enumerateDeviceHandles()` produces. So, unlike everything else this PR
/// adds, this is genuinely unit-testable with synthetic data and no
/// hardware (CI rule: no test may require a live camera). See
/// `CMIODeviceLookupTests` for the coverage: found, not-found, and
/// no-false-positive-on-empty-list cases.
///
/// The underlying assumption this whole feature rests on — that
/// CoreMediaIO's `kCMIODevicePropertyDeviceUID` for a given camera equals
/// that same camera's `AVCaptureDevice.uniqueID` — follows from
/// AVFoundation's video capture stack being built on CoreMediaIO's DAL on
/// macOS, and is consistent with §12.2's reference-probe measurement (which
/// enumerated the built-in camera, an iPhone Continuity camera, and a Desk
/// View camera by name through the CMIO device list — the same physical set
/// AVFoundation enumerates). It is NOT independently re-verified by this
/// PR; if a maintainer's live `probe-camera` run ever shows a selected
/// `AVCaptureDevice.uniqueID` failing to match any CMIO device UID despite
/// the device being genuinely present, that assumption is the first thing
/// to question.
public enum CMIODeviceLookup {
  /// Returns the `CMIOObjectID` of the handle whose `uid` exactly equals
  /// `uniqueID`, or `nil` if none match. Exact-string comparison only — no
  /// normalization, no case-folding: `AVCaptureDevice.uniqueID` and
  /// CoreMediaIO's `kCMIODevicePropertyDeviceUID` are both opaque identifier
  /// strings, not user-facing text, so treating them as anything other than
  /// exact byte-for-byte tokens would risk a false match.
  public static func match(uniqueID: String, in handles: [CMIODeviceHandle]) -> CMIOObjectID? {
    handles.first(where: { $0.uid == uniqueID })?.objectID
  }
}
