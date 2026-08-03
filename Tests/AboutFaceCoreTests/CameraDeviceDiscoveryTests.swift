import Foundation
import Testing

@testable import AboutFaceCore

/// `CameraDeviceDiscovery` (§12.1): the snapshot-publishing policy, tested
/// against a fake `CameraDeviceProvider` — no `AVCaptureDevice.DiscoverySession`
/// involved, so this runs without a live camera (CI rule).
struct CameraDeviceDiscoveryTests {
  @Test("start() yields an immediate snapshot from currentDevices()")
  func startYieldsImmediateSnapshot() async {
    let initial = [CameraDeviceDescriptor(id: "a", localizedName: "Camera A")]
    let provider = MockCameraDeviceProvider(initial: initial)
    let discovery = CameraDeviceDiscovery(provider: provider)

    await discovery.start()
    var iterator = discovery.devices.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == initial)
  }

  @Test("A provider-reported change publishes a fresh full snapshot")
  func changePublishesFreshSnapshot() async {
    let provider = MockCameraDeviceProvider(initial: [])
    let discovery = CameraDeviceDiscovery(provider: provider)

    await discovery.start()
    var iterator = discovery.devices.makeAsyncIterator()
    _ = await iterator.next()  // initial (empty) snapshot

    let updated = [CameraDeviceDescriptor(id: "b", localizedName: "Continuity Camera")]
    provider.simulateChange(to: updated)
    let second = await iterator.next()
    #expect(second == updated)
  }

  @Test("start() is idempotent — a second call does not re-register or duplicate delivery")
  func startIsIdempotent() async {
    let provider = MockCameraDeviceProvider(initial: [])
    let discovery = CameraDeviceDiscovery(provider: provider)

    await discovery.start()
    await discovery.start()
    #expect(provider.observerCount == 1)
  }

  @Test("stop() finishes the stream and unregisters from the provider")
  func stopFinishesStreamAndUnregisters() async {
    let provider = MockCameraDeviceProvider(initial: [])
    let discovery = CameraDeviceDiscovery(provider: provider)

    await discovery.start()
    await discovery.stop()
    #expect(provider.observerCount == 0)

    var count = 0
    for await _ in discovery.devices { count += 1 }
    #expect(count == 1)  // the initial snapshot, buffered before stop() finished the stream
  }
}

/// Fake `CameraDeviceProvider`: no `AVFoundation` involved, so
/// `CameraDeviceDiscovery`'s publishing policy can be exercised
/// deterministically from a test, including simulating a Continuity Camera
/// device appearing/disappearing without needing one physically present.
final class MockCameraDeviceProvider: CameraDeviceProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var current: [CameraDeviceDescriptor]
  private var handlers: [UUID: @Sendable ([CameraDeviceDescriptor]) -> Void] = [:]

  init(initial: [CameraDeviceDescriptor]) {
    self.current = initial
  }

  var observerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return handlers.count
  }

  func currentDevices() -> [CameraDeviceDescriptor] {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func startObserving(
    onChange: @escaping @Sendable ([CameraDeviceDescriptor]) -> Void
  ) -> CameraDeviceObservationToken {
    let token = CameraDeviceObservationToken()
    lock.lock()
    handlers[token.id] = onChange
    lock.unlock()
    return token
  }

  func stopObserving(_ token: CameraDeviceObservationToken) {
    lock.lock()
    handlers.removeValue(forKey: token.id)
    lock.unlock()
  }

  /// Test-only: simulates the underlying device list changing, invoking
  /// every currently-registered observer — stands in for what a KVO change
  /// notification on a real `AVCaptureDevice.DiscoverySession` would do.
  func simulateChange(to devices: [CameraDeviceDescriptor]) {
    lock.lock()
    current = devices
    let observers = Array(handlers.values)
    lock.unlock()
    for observer in observers {
      observer(devices)
    }
  }
}
