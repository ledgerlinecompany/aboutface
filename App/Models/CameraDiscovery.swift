import AVFoundation
import Observation

/// One entry in the camera picker: `AVCaptureDevice.uniqueID` plus a
/// human-readable name (spec §9's "Camera picker (device name +
/// uniqueID)"). Deliberately just two plain `String`s — see
/// `CameraDiscovery`'s doc comment for why no `AVCaptureDevice` value ever
/// crosses an isolation boundary.
public struct CameraDevice: Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let displayName: String
}

/// Observes the system's live camera list, per spec §12.1: "Enumerate with
/// an observed `AVCaptureDevice.DiscoverySession`, not a snapshot at
/// launch — Continuity Camera devices come and go."
///
/// ## Concurrency
///
/// `AVCaptureDevice.DiscoverySession` and `AVCaptureDevice` are
/// AVFoundation types that predate Swift concurrency and are not reliably
/// `Sendable`-annotated across SDKs — CLAUDE.md's toolchain note says never
/// to rely on an SDK's `Sendable` annotation for an AVFoundation value
/// crossing an isolation boundary, the same reasoning
/// `CameraCaptureSource`'s `SessionBox` and `FileCaptureSource`'s
/// `ReaderBox` already apply to this codebase's other AVFoundation
/// touchpoints. KVO delivers `devices` changes on an unspecified thread —
/// not necessarily the main actor — so this type extracts only the two
/// `Sendable` `String`s each `AVCaptureDevice` needs for `CameraDevice`
/// entirely inside that (arbitrary-thread) callback, then hops to the main
/// actor with only that already-`Sendable` `[CameraDevice]` array. No
/// `AVCaptureDevice` or `DiscoverySession` value itself ever crosses the
/// boundary.
@MainActor
@Observable
public final class CameraDiscovery {
  public private(set) var devices: [CameraDevice] = []

  private let session = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
    mediaType: .video,
    position: .unspecified
  )
  private var observation: NSKeyValueObservation?

  public init() {
    devices = Self.mapDevices(session.devices)
    // `devices` is documented KVO-compliant on `AVCaptureDevice.DiscoverySession`
    // (§12.1: Continuity Camera devices "come and go"). The maintainer
    // should verify this empirically against real Continuity Camera
    // connect/disconnect events per the manual checklist — see
    // docs/acceptance/phase2-checklist.md.
    observation = session.observe(\.devices, options: [.new]) { [weak self] _, change in
      let mapped = Self.mapDevices(change.newValue ?? [])
      Task { @MainActor in
        self?.devices = mapped
      }
    }
  }

  private nonisolated static func mapDevices(_ devices: [AVCaptureDevice]) -> [CameraDevice] {
    devices.map { CameraDevice(id: $0.uniqueID, displayName: $0.localizedName) }
  }
}
