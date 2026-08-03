// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore
import AppKit
import Foundation

// swiftlint:enable sorted_imports

/// Explicit camera selection (§12.1) and camera permission (§9/§12). Split
/// out of `PipelineModel.swift` purely to keep each file a manageable size
/// (see that file's doc comment); everything here is still `PipelineModel`'s
/// own implementation, not a separate public surface.
extension PipelineModel {

  // MARK: - Camera selection (§12.1)

  /// The ONLY call site that persists a camera choice into `Config.Camera
  /// .selectedCameraID` — and therefore the only way `Config.isConfigured`'s
  /// camera half can ever become `true`. Called from `SetupWindowView`'s
  /// camera `Picker`, which is the one place that actually knows a HUMAN
  /// made this choice (§12.1: "User explicitly selects the camera") —
  /// never from `init()`'s auto-default assignment in `PipelineModel
  /// .swift`, which sets `selectedCameraID` directly for exactly this
  /// reason. See that assignment's own comment for the failure mode
  /// merging the two paths would reopen.
  ///
  /// A `nil` argument (the Picker's "Select a camera" placeholder row) is
  /// itself a legitimate explicit choice — a user actively clearing their
  /// selection — and persists as `nil` like any other write here; it is
  /// not the same `nil` as "never touched," which `Config.isConfigured`
  /// only sees via the OTHER half of its predicate (`targetFraming
  /// .captured`) once neither is set.
  public func selectCamera(_ deviceID: String?) {
    selectedCameraID = deviceID
    var updated = config
    updated.camera.selectedCameraID = deviceID
    updateConfig(updated)
  }

  // MARK: - Camera permission (§9/§12)

  /// Requests camera access if not already determined. No-op otherwise —
  /// once the user has answered, only System Settings can change it, which
  /// is what `openSystemSettingsForCameraPrivacy()` is for.
  public func requestCameraPermission() async {
    guard permissionState == .notDetermined else { return }
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .video) { granted in
        continuation.resume(returning: granted)
      }
    }
    permissionState = granted ? .authorized : .denied
  }

  /// Deep-links to the Camera privacy pane so a denied user can fix it
  /// without hunting through System Settings (spec §9's permission-flow
  /// requirement: "show a clear message + System Settings link when
  /// denied").
  public func openSystemSettingsForCameraPrivacy() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}
