import Foundation
import Testing

@testable import AboutFaceCore

/// `CameraInUseMonitor` (§12.2's platform-probe layer): the
/// publish-a-stream-of-busy-states policy, tested against a fake
/// `CameraBusyProvider` — no real `AVCaptureDevice` involved, so this runs
/// without a live camera (CI rule) and without needing a second process to
/// actually grab it.
struct CameraInUseMonitorTests {
  @Test("start() yields an immediate value from currentValue() and records the reported path")
  func startYieldsImmediateValueAndPath() async {
    let provider = MockCameraBusyProvider(initial: false, path: .kvo)
    let monitor = CameraInUseMonitor(provider: provider)

    await monitor.start()
    var iterator = monitor.busyStates.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == false)
    #expect(await monitor.activePath == .kvo)
  }

  @Test("Reports .polling when the provider falls back to polling")
  func reportsPollingPath() async {
    let provider = MockCameraBusyProvider(initial: false, path: .polling)
    let monitor = CameraInUseMonitor(provider: provider)

    await monitor.start()
    #expect(await monitor.activePath == .polling)
  }

  @Test("A provider-reported change publishes the new value")
  func changePublishesNewValue() async {
    let provider = MockCameraBusyProvider(initial: false)
    let monitor = CameraInUseMonitor(provider: provider)

    await monitor.start()
    var iterator = monitor.busyStates.makeAsyncIterator()
    _ = await iterator.next()  // initial value

    provider.simulateChange(to: true)
    let second = await iterator.next()
    #expect(second == true)

    provider.simulateChange(to: false)
    let third = await iterator.next()
    #expect(third == false)
  }

  @Test("start() is idempotent")
  func startIsIdempotent() async {
    let provider = MockCameraBusyProvider(initial: false)
    let monitor = CameraInUseMonitor(provider: provider)

    await monitor.start()
    await monitor.start()
    #expect(provider.observerCount == 1)
  }

  @Test("stop() finishes the stream, unregisters, and clears activePath")
  func stopFinishesStreamAndClearsPath() async {
    let provider = MockCameraBusyProvider(initial: false)
    let monitor = CameraInUseMonitor(provider: provider)

    await monitor.start()
    await monitor.stop()
    #expect(provider.observerCount == 0)
    #expect(await monitor.activePath == nil)

    var count = 0
    for await _ in monitor.busyStates { count += 1 }
    #expect(count == 1)  // the initial value, buffered before stop() finished the stream
  }
}

/// Fake `CameraBusyProvider`: no `AVFoundation` involved, so
/// `CameraInUseMonitor`'s publishing policy can be exercised deterministically
/// — including simulating "another app grabbed the camera," which a headless
/// CI run cannot do for real (that needs a second live process — see
/// `AVCaptureDeviceBusyProvider`'s doc comment and the PR report's
/// maintainer-verification note).
final class MockCameraBusyProvider: CameraBusyProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Bool
  private var handler: (@Sendable (Bool) -> Void)?
  private let path: CameraBusyObservationPath

  init(initial: Bool, path: CameraBusyObservationPath = .kvo) {
    self.current = initial
    self.path = path
  }

  var observerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return handler == nil ? 0 : 1
  }

  func currentValue() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func startObserving(
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> CameraBusyObservationStart {
    let token = CameraBusyObservationToken()
    lock.lock()
    handler = onChange
    lock.unlock()
    return CameraBusyObservationStart(token: token, path: path)
  }

  func stopObserving(_ token: CameraBusyObservationToken) {
    lock.lock()
    handler = nil
    lock.unlock()
  }

  /// Test-only: simulates a busy-state change, invoking the registered
  /// observer — stands in for what a real KVO/poll-detected change would do.
  func simulateChange(to value: Bool) {
    lock.lock()
    current = value
    let observer = handler
    lock.unlock()
    observer?(value)
  }
}
