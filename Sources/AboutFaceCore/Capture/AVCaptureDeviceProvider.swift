import AVFoundation
import Foundation

/// The real, `AVCaptureDevice.DiscoverySession`-backed `CameraDeviceProvider`
/// (§12.1: "Enumerate with an observed `AVCaptureDevice.DiscoverySession`,
/// **not** a snapshot at launch — Continuity Camera devices come and go").
///
/// ## Concurrency
///
/// Per the CLAUDE.md toolchain-skew rule (see `FileCaptureSource.makeReader`
/// /`ReaderBox` for the reference pattern this follows), every AVFoundation
/// touchpoint — creating the `DiscoverySession`, registering KVO, reading
/// `uniqueID`/`localizedName` — happens inside this one type, and only the
/// `Sendable` `CameraDeviceDescriptor` snapshots defined by
/// `CameraDeviceProvider` ever cross out of it. This class is not an actor
/// (its protocol is called from a plain closure-based KVO callback, which
/// can fire on any thread — wrapping it in an actor would just add an
/// `await` hop before the `Sendable` snapshot can be published, for no
/// safety benefit), so it manages its own small bit of mutable bookkeeping
/// (the live `DiscoverySession`/observation per outstanding token) behind an
/// `NSLock`. `@unchecked Sendable` reflects that explicit, audited
/// synchronization — not a bypass.
public final class AVCaptureDeviceProvider: CameraDeviceProvider, @unchecked Sendable {
  // swift-format requires trailing commas in multiline collection literals;
  // swiftlint's default forbids them. Same documented conflict as
  // ConfigStore.swift; format wins.
  // swiftlint:disable trailing_comma
  /// The device types the app cares about — matches
  /// `CameraCaptureSource.configureSession`'s discovery so enumeration and
  /// actual capture agree on what counts as "a camera."
  public static let defaultDeviceTypes: [AVCaptureDevice.DeviceType] = [
    .builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera,
  ]
  // swiftlint:enable trailing_comma

  private let deviceTypes: [AVCaptureDevice.DeviceType]
  private let mediaType: AVMediaType
  private let position: AVCaptureDevice.Position

  private let lock = NSLock()
  private var liveSessions: [UUID: DiscoverySessionBox] = [:]
  private var liveObservations: [UUID: NSKeyValueObservation] = [:]

  public init(
    deviceTypes: [AVCaptureDevice.DeviceType] = AVCaptureDeviceProvider.defaultDeviceTypes,
    mediaType: AVMediaType = .video,
    position: AVCaptureDevice.Position = .unspecified
  ) {
    self.deviceTypes = deviceTypes
    self.mediaType = mediaType
    self.position = position
  }

  public func currentDevices() -> [CameraDeviceDescriptor] {
    Self.snapshot(of: makeSession())
  }

  public func startObserving(
    onChange: @escaping @Sendable ([CameraDeviceDescriptor]) -> Void
  ) -> CameraDeviceObservationToken {
    let token = CameraDeviceObservationToken()
    let session = makeSession()
    // `devices` is documented KVO-observable on `AVCaptureDevice.DiscoverySession`
    // — this is the mechanism §12.1 asks for, distinct from the genuinely
    // uncertain §12.2 `isInUseByAnotherApplication` KVO question handled in
    // `AVCaptureDeviceBusyProvider`.
    let observation = session.observe(\.devices, options: [.new]) { observedSession, _ in
      onChange(Self.snapshot(of: observedSession))
    }

    lock.lock()
    liveSessions[token.id] = DiscoverySessionBox(session)
    liveObservations[token.id] = observation
    lock.unlock()

    return token
  }

  public func stopObserving(_ token: CameraDeviceObservationToken) {
    lock.lock()
    let observation = liveObservations.removeValue(forKey: token.id)
    liveSessions.removeValue(forKey: token.id)
    lock.unlock()
    observation?.invalidate()
  }

  private func makeSession() -> AVCaptureDevice.DiscoverySession {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes, mediaType: mediaType, position: position)
  }

  private static func snapshot(
    of session: AVCaptureDevice.DiscoverySession
  ) -> [CameraDeviceDescriptor] {
    session.devices.map { CameraDeviceDescriptor(id: $0.uniqueID, localizedName: $0.localizedName) }
  }
}

/// Keeps a `DiscoverySession` alive for as long as it has a live KVO
/// observation registered on it — `NSKeyValueObservation` does not retain
/// its observed object. `@unchecked Sendable`: touched only while
/// `AVCaptureDeviceProvider.lock` is held, matching
/// `CameraCaptureSource.SessionBox`'s ownership-transfer rationale.
private final class DiscoverySessionBox: @unchecked Sendable {
  let session: AVCaptureDevice.DiscoverySession

  init(_ session: AVCaptureDevice.DiscoverySession) {
    self.session = session
  }
}
