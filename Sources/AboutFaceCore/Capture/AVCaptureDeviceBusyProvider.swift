import AVFoundation
import Foundation

/// The real `CameraBusyProvider` for §12.2's camera-in-use gating: watches
/// `AVCaptureDevice.isInUseByAnotherApplication` for the selected device.
///
/// ## Which path does this take?
///
/// Apple declares `isInUseByAnotherApplication` `@objc dynamic` in the
/// public header, which is the prerequisite for automatic KVO — so this
/// type always **attempts** KVO registration first (`forcePolling == false`,
/// the default), and that registration call itself cannot fail
/// synchronously (Cocoa KVO registration on a `dynamic` property doesn't
/// throw). That means `startObserving` will, in practice, always report
/// `.kvo` here.
///
/// What a headless build/test run genuinely **cannot** verify is whether
/// that KVO registration actually *fires* when another process opens the
/// camera — doing so requires a second real process holding the device
/// during a live session, which is a maintainer verification step (see the
/// PR report), not something CI can exercise. `forcePolling` exists as the
/// escape hatch for that finding: if live testing shows KVO silently never
/// fires on some macOS version, flip it on (config-keyed —
/// `Config.Camera.forceBusyPolling`, §0) rather than rewriting this type.
/// This is the "dual-path design makes the answer an observation, not a
/// rewrite" the spec asks for.
///
/// ## Concurrency
///
/// Same rationale as `AVCaptureDeviceProvider`: not an actor (KVO/poll
/// callbacks fire off arbitrary threads regardless), all AVFoundation
/// touchpoints stay inside this type, only `Sendable` `Bool` values cross
/// out via `onChange`, and the small bit of mutable bookkeeping (live
/// observation/poll task per token) is guarded by an `NSLock`.
public final class AVCaptureDeviceBusyProvider: CameraBusyProvider, @unchecked Sendable {
  private let deviceUniqueID: String
  private let pollIntervalSeconds: Double
  private let forcePolling: Bool
  private let deviceTypes: [AVCaptureDevice.DeviceType]

  private let lock = NSLock()
  private var liveObservations: [UUID: NSKeyValueObservation] = [:]
  private var livePollTasks: [UUID: Task<Void, Never>] = [:]

  /// - Parameters:
  ///   - deviceUniqueID: `AVCaptureDevice.uniqueID` of the device to watch.
  ///     Resolved from the observed device list at `currentValue()`/
  ///     `startObserving` time, not cached — matches
  ///     `CameraCaptureSource.deviceUniqueID`'s "resolved at start() time,
  ///     not cached at init" rationale.
  ///   - pollIntervalSeconds: Poll cadence for the fallback path. §12.2's
  ///     "poll at 1 Hz" is a starting point (§0), config-keyed as
  ///     `Config.Camera.busyPollIntervalSeconds` by callers — not
  ///     hardcoded here.
  ///   - forcePolling: See the type-level doc comment. Default `false`
  ///     (attempt KVO).
  public init(
    deviceUniqueID: String,
    pollIntervalSeconds: Double = 1.0,
    forcePolling: Bool = false,
    deviceTypes: [AVCaptureDevice.DeviceType] = AVCaptureDeviceProvider.defaultDeviceTypes
  ) {
    self.deviceUniqueID = deviceUniqueID
    self.pollIntervalSeconds = pollIntervalSeconds
    self.forcePolling = forcePolling
    self.deviceTypes = deviceTypes
  }

  public func currentValue() -> Bool {
    resolveDevice()?.isInUseByAnotherApplication ?? false
  }

  public func startObserving(
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> CameraBusyObservationStart {
    let token = CameraBusyObservationToken()

    guard let device = resolveDevice() else {
      // Device not found (disconnected, or a stale/bad ID): nothing to
      // observe yet. Reported as `.polling` since there is no live KVO
      // subscription in this state — `currentValue()` keeps returning
      // `false` via the same not-found path until the device reappears;
      // there is deliberately no retry loop here, since re-resolution is a
      // §12.1 device-discovery concern, not this type's.
      return CameraBusyObservationStart(token: token, path: .polling)
    }

    if forcePolling {
      startPolling(device: device, tokenID: token.id, onChange: onChange)
      return CameraBusyObservationStart(token: token, path: .polling)
    }

    let observation = device.observe(\.isInUseByAnotherApplication, options: [.new]) { _, change in
      guard let newValue = change.newValue else { return }
      onChange(newValue)
    }
    lock.lock()
    liveObservations[token.id] = observation
    lock.unlock()
    return CameraBusyObservationStart(token: token, path: .kvo)
  }

  public func stopObserving(_ token: CameraBusyObservationToken) {
    lock.lock()
    let observation = liveObservations.removeValue(forKey: token.id)
    let pollTask = livePollTasks.removeValue(forKey: token.id)
    lock.unlock()
    observation?.invalidate()
    pollTask?.cancel()
  }

  private func resolveDevice() -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
    return discovery.devices.first(where: { $0.uniqueID == deviceUniqueID })
  }

  private func startPolling(
    device: AVCaptureDevice,
    tokenID: UUID,
    onChange: @escaping @Sendable (Bool) -> Void
  ) {
    let box = DeviceBox(device)
    let interval = pollIntervalSeconds
    let task = Task {
      var lastValue = box.device.isInUseByAnotherApplication
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { break }
        let value = box.device.isInUseByAnotherApplication
        if value != lastValue {
          lastValue = value
          onChange(value)
        }
      }
    }
    lock.lock()
    livePollTasks[tokenID] = task
    lock.unlock()
  }
}

/// Ownership-transfer wrapper so the non-`Sendable` `AVCaptureDevice` can be
/// captured by the polling `Task`'s closure — same rationale as
/// `CameraCaptureSource.SessionBox`: exclusive handoff into one task's
/// sequential loop, not concurrent sharing.
private final class DeviceBox: @unchecked Sendable {
  let device: AVCaptureDevice

  init(_ device: AVCaptureDevice) {
    self.device = device
  }
}
