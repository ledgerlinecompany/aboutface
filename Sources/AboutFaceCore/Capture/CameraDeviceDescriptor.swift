/// A plain `Sendable` snapshot of one camera device, for the §12.1 selection
/// UI and anything else that needs to enumerate cameras without touching
/// `AVFoundation` directly.
///
/// Deliberately minimal — just enough to populate a picker and to resolve
/// back to `AVCaptureDevice.uniqueID` (`id`) when a session actually opens
/// the device. `AVCaptureDevice` itself never crosses an isolation boundary
/// (see `CameraDeviceProvider`'s doc comment for why); this value type is
/// what does instead.
public struct CameraDeviceDescriptor: Sendable, Equatable, Identifiable, Codable {
  /// `AVCaptureDevice.uniqueID` — stable for a given physical/virtual device
  /// across relaunches, and what `Config.Camera.selectedCameraID` stores.
  public let id: String

  /// `AVCaptureDevice.localizedName` — human-readable, for display only.
  /// Never used as a lookup key: names are not guaranteed unique (two
  /// identical external webcams) or stable (a user can rename some devices).
  public let localizedName: String

  public init(id: String, localizedName: String) {
    self.id = id
    self.localizedName = localizedName
  }
}
