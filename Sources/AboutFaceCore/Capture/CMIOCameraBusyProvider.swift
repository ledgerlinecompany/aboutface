import CoreMediaIO
import Foundation

/// The `CameraBusyProvider` §12.2 asks for once
/// `AVCaptureDeviceBusyProvider`'s `isInUseByAnotherApplication` was found
/// not to work: watches CoreMediaIO's
/// `kCMIODevicePropertyDeviceIsRunningSomewhere` for the device whose
/// `AVCaptureDevice.uniqueID` matches `deviceUniqueID`, via
/// `CMIODeviceLookup.match` (never by assuming enumeration order — the PR
/// brief's explicit instruction).
///
/// **Currently unwired**, same status as `AVCaptureDeviceBusyProvider`: this
/// type is a proper, tested-where-testable conformance, but nothing in
/// `App/` consumes it in a live activation or reminder path yet — that is
/// deliberately later work (see §12.2's "Proposed direction" and this PR's
/// brief). Read §12.2 before wiring this into one.
///
/// ## `currentValue()` vs. `currentReading()` — and why `.deviceNotFound`
/// can no longer hide behind either
///
/// An earlier revision of this type let `init` accept any `deviceUniqueID`
/// unconditionally, deferring resolution to `currentValue()`/
/// `currentReading()`. That meant an unresolvable ID produced an indefinite
/// stream of `currentValue() == false` — exactly indistinguishable from
/// "camera genuinely idle," forever, with no error anywhere. That is the
/// precise shape of §12.2's finding: `isInUseByAnotherApplication` also
/// "worked," also returned a plausible `false`, and the failure was only
/// caught by an independent measurement, not by anything in the code
/// admitting uncertainty. A doc comment describing the ambiguity was not
/// enough to prevent that once — there is no reason to trust it would be
/// enough the next time a caller wires this up without re-reading it.
///
/// So `init` now resolves `deviceUniqueID` to a `CMIOObjectID` immediately
/// and `throws CMIOCameraBusyProviderError.deviceNotFound` if nothing
/// matches — see `init`'s doc comment. That closes the permanent
/// silent-`false` path structurally: a provider for a device that does not
/// exist simply cannot be constructed. `currentValue() -> Bool`, fixed at
/// `Bool` by the protocol, therefore only has to represent genuinely
/// transient outcomes after that point — a device that resolved at
/// construction but has since disconnected (a USB webcam unplugged
/// mid-session), or a one-off property-read error — not "never existed at
/// all." `currentReading() -> CMIORunningSomewhereReading`, a member of
/// this concrete type but not of `CameraBusyProvider`, remains the
/// non-lossy answer for those transient cases, distinguishing `.idle` from
/// `.deviceNotFound` (now: "disappeared after construction," not "never
/// resolved") from `.propertyReadFailed(OSStatus)`. Callers that only need
/// a `Bool` get the narrowed answer for a much smaller, more defensible set
/// of cases than before; callers that need to know why — tests, and
/// `probe-camera`'s CMIO reporting (§12.6) — call `currentReading()`
/// directly.
///
/// ## Which path does this take?
///
/// Unlike `isInUseByAnotherApplication` (`@objc dynamic`, so KVO
/// registration cannot fail synchronously), `CMIOObjectAddPropertyListenerBlock`
/// is a real registration call against a real `CMIOObjectID` that returns an
/// `OSStatus` — it CAN fail. So, unlike `AVCaptureDeviceBusyProvider`, this
/// type's `startObserving` genuinely does not know in advance which path it
/// will report: it attempts the listener first (`forcePolling == false`,
/// the default) and only falls back to polling if registration itself
/// returns a non-`noErr` status.
///
/// **What is and isn't verified**, stated plainly per the PR brief (the
/// previous provider's doc comment is the model for this section, and for
/// why the distinction matters — §12.2's whole finding was discovered
/// because a "should work" signal wasn't independently checked):
///
/// - Polling `kCMIODevicePropertyDeviceIsRunningSomewhere` IS empirically
///   verified — §12.2 measured exactly this property, by repeated reads,
///   tracking a real Zoom call correctly and reversibly (false → true →
///   false). The polling fallback path this type falls back to rests on
///   that measurement.
/// - Listener registration succeeding (`CMIOObjectAddPropertyListenerBlock`
///   returning `noErr`) is NOT the same claim as the listener block firing
///   when another process starts or stops streaming. Verifying that needs a
///   second real process holding the device during a live session — a
///   maintainer verification step (see the PR report), not something CI or
///   this sandbox can exercise (constraint: no live-camera commands here).
/// - `forcePolling` (mirroring `AVCaptureDeviceBusyProvider`'s escape
///   hatch, same `Config.Camera.forceBusyPolling` field) exists for exactly
///   the case where live testing shows the listener registers but never
///   fires: flip it rather than rewriting this type.
///
/// ## Concurrency
///
/// Per the CLAUDE.md toolchain rule: `CMIOObjectAddPropertyListenerBlock`'s
/// block runs on the `DispatchQueue` passed at registration — a domain of
/// its own, distinct from whatever isolation context called
/// `startObserving`. The block captures only `objectID` (a `CMIOObjectID`,
/// i.e. `UInt32` — trivially `Sendable`) and the caller's `@Sendable
/// onChange`; it re-reads the property itself via `CMIOPropertyReader`
/// rather than trusting any state computed before registration, and only
/// the resulting `Sendable Bool` crosses back out through `onChange`. Not
/// an actor, for the same reason `AVCaptureDeviceBusyProvider` isn't: the
/// listener block and poll `Task` fire on their own schedules regardless,
/// so the small bit of mutable bookkeeping (live listener/poll-task per
/// token) is guarded by an `NSLock` instead.
/// Thrown by `CMIOCameraBusyProvider.init` — see that type's doc comment
/// for why resolution failure is a construction-time error rather than a
/// value `currentValue()`/`currentReading()` could return silently.
public enum CMIOCameraBusyProviderError: Error, Sendable, Equatable {
  /// No CMIO device's `kCMIODevicePropertyDeviceUID` matched the given
  /// `AVCaptureDevice.uniqueID` at construction time.
  case deviceNotFound(String)
}

public final class CMIOCameraBusyProvider: CameraBusyProvider, @unchecked Sendable {
  private let deviceUniqueID: String
  private let pollIntervalSeconds: Double
  private let forcePolling: Bool

  private let lock = NSLock()
  private var liveListeners: [UUID: ListenerRegistration] = [:]
  private var livePollTasks: [UUID: Task<Void, Never>] = [:]

  /// Fails construction if `deviceUniqueID` cannot be resolved to a
  /// `CMIOObjectID` at this instant — see this type's "currentValue() vs.
  /// currentReading()" doc section for why that check lives here and not
  /// only in a later read. Resolution is NOT cached past this point: every
  /// `currentValue()`/`currentReading()`/`startObserving` call re-resolves
  /// `deviceUniqueID` fresh via `CMIODeviceLookup`, same rationale as
  /// `AVCaptureDeviceBusyProvider.resolveDevice()` — a device that existed
  /// at construction and later disappears is a real, transient outcome
  /// this initializer does not and cannot rule out, and `currentReading()`
  /// still reports it honestly as `.deviceNotFound` if it happens.
  ///
  /// - Parameters:
  ///   - deviceUniqueID: `AVCaptureDevice.uniqueID` of the device to watch.
  ///   - pollIntervalSeconds: Poll cadence for the fallback path —
  ///     `Config.Camera.busyPollIntervalSeconds` by convention (same field
  ///     `AVCaptureDeviceBusyProvider` reads; §0: not hardcoded here).
  ///   - forcePolling: See the type-level doc comment's "what is and isn't
  ///     verified" section. Default `false` (attempt the CMIO listener).
  /// - Throws: `CMIOCameraBusyProviderError.deviceNotFound(deviceUniqueID)`
  ///   if no CMIO device's UID matches `deviceUniqueID` right now.
  public init(
    deviceUniqueID: String,
    pollIntervalSeconds: Double = 1.0,
    forcePolling: Bool = false
  ) throws {
    guard
      CMIODeviceLookup.match(
        uniqueID: deviceUniqueID, in: CMIOPropertyReader.enumerateDeviceHandles()) != nil
    else {
      throw CMIOCameraBusyProviderError.deviceNotFound(deviceUniqueID)
    }
    self.deviceUniqueID = deviceUniqueID
    self.pollIntervalSeconds = pollIntervalSeconds
    self.forcePolling = forcePolling
  }

  public func currentValue() -> Bool {
    currentReading() == .running
  }

  /// The non-lossy reading — see this type's "currentValue() vs.
  /// currentReading()" doc section.
  public func currentReading() -> CMIORunningSomewhereReading {
    CMIOPropertyReader.runningSomewhere(forUniqueID: deviceUniqueID)
  }

  public func startObserving(
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> CameraBusyObservationStart {
    let token = CameraBusyObservationToken()

    guard
      let objectID = CMIODeviceLookup.match(
        uniqueID: deviceUniqueID, in: CMIOPropertyReader.enumerateDeviceHandles())
    else {
      // Device not found: `init` guaranteed a match at construction time
      // (see this type's doc comment), so reaching this means the device
      // has genuinely disappeared since then (e.g. a USB webcam unplugged
      // mid-session) -- a real, transient case `init` cannot rule out.
      // Nothing to observe yet, same "no retry loop, this is a §12.1
      // discovery concern" stance as `AVCaptureDeviceBusyProvider`.
      // `currentReading()` keeps returning `.deviceNotFound` (not silently
      // `.idle`) via the same path until the device reappears.
      return CameraBusyObservationStart(token: token, path: .polling)
    }

    if forcePolling {
      startPolling(objectID: objectID, tokenID: token.id, onChange: onChange)
      return CameraBusyObservationStart(token: token, path: .polling)
    }

    if let registration = Self.registerListener(objectID: objectID, onChange: onChange) {
      lock.lock()
      liveListeners[token.id] = registration
      lock.unlock()
      return CameraBusyObservationStart(token: token, path: .cmioListener)
    }

    // Listener registration itself failed (non-`noErr`) -- fall back, per
    // this type's doc comment.
    startPolling(objectID: objectID, tokenID: token.id, onChange: onChange)
    return CameraBusyObservationStart(token: token, path: .polling)
  }

  public func stopObserving(_ token: CameraBusyObservationToken) {
    lock.lock()
    let registration = liveListeners.removeValue(forKey: token.id)
    let pollTask = livePollTasks.removeValue(forKey: token.id)
    lock.unlock()

    if let registration {
      var address = registration.address
      CMIOObjectRemovePropertyListenerBlock(
        registration.objectID, &address, registration.queue, registration.block)
    }
    pollTask?.cancel()
  }

  /// Registers a CMIO property listener block for `objectID`, returning the
  /// live registration (needed verbatim by `stopObserving` -- CoreMediaIO
  /// requires the exact same block/queue/address to unregister) or `nil` if
  /// registration itself failed.
  private static func registerListener(
    objectID: CMIOObjectID,
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> ListenerRegistration? {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let queue = DispatchQueue(label: "com.ledgerlinecompany.aboutface.cmio-busy-listener")

    // See this type's "Concurrency" doc section: runs on `queue`, its own
    // domain, and re-reads the property itself rather than trusting
    // anything computed before registration.
    let block: CMIOObjectPropertyListenerBlock = { _, _ in
      let reading = CMIOPropertyReader.runningSomewhere(objectID)
      onChange(reading == .running)
    }

    let status = CMIOObjectAddPropertyListenerBlock(objectID, &address, queue, block)
    guard status == noErr else { return nil }
    return ListenerRegistration(objectID: objectID, address: address, queue: queue, block: block)
  }

  private func startPolling(
    objectID: CMIOObjectID,
    tokenID: UUID,
    onChange: @escaping @Sendable (Bool) -> Void
  ) {
    let interval = pollIntervalSeconds
    let task = Task {
      var lastValue = CMIOPropertyReader.runningSomewhere(objectID) == .running
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { break }
        let value = CMIOPropertyReader.runningSomewhere(objectID) == .running
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

/// What `stopObserving` needs to unregister a listener: CoreMediaIO
/// requires the exact same objectID/address/queue/block used at
/// registration. `@unchecked Sendable`: touched only while
/// `CMIOCameraBusyProvider.lock` is held, matching `DeviceBox`'s
/// ownership-transfer rationale in `AVCaptureDeviceBusyProvider.swift`.
private struct ListenerRegistration: @unchecked Sendable {
  let objectID: CMIOObjectID
  let address: CMIOObjectPropertyAddress
  let queue: DispatchQueue
  let block: CMIOObjectPropertyListenerBlock
}
