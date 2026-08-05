import AVFoundation
import Testing

@testable import AboutFaceCore

/// `AVCaptureDeviceProvider` / `AVCaptureDeviceBusyProvider` open a real
/// `AVCaptureDevice.DiscoverySession` and require camera hardware/permission
/// to do anything useful, which CI does not have (per CLAUDE.md: "never
/// write tests that require a live camera to pass in CI") — same rationale
/// as `CameraCaptureSourceCompileOnlyTests`. These tests only exercise
/// construction, never `currentDevices()`/`startObserving`/`start()`, which
/// is enough to prove the types compile and their protocol conformances are
/// wired correctly. The behavioral tests for the policy these types serve
/// live in `CameraDeviceDiscoveryTests`/`CameraInUseMonitorTests`, against
/// mock providers.
struct CameraProbeCompileOnlyTests {
  @Test("AVCaptureDeviceProvider constructs with its documented default device types")
  func deviceProviderConstructs() {
    let provider = AVCaptureDeviceProvider()
    _ = provider as any CameraDeviceProvider
    #expect(!AVCaptureDeviceProvider.defaultDeviceTypes.isEmpty)
  }

  @Test("AVCaptureDeviceBusyProvider constructs and conforms to CameraBusyProvider")
  func busyProviderConstructs() {
    let provider = AVCaptureDeviceBusyProvider(deviceUniqueID: "nonexistent-device-for-testing")
    _ = provider as any CameraBusyProvider
  }

  // `CMIOCameraBusyProvider`, `CMIOPropertyReader`, and
  // `CMIOAllDevicesBusyReader` all talk to real CoreMediaIO hardware
  // objects, which (like `AVCaptureDeviceProvider`/`AVCaptureDeviceBusyProvider`
  // above) CI cannot rely on doing anything useful with -- so these never
  // invoke `currentValue()`/`currentReading()`/`startObserving()`/
  // `currentRunningStates()` on a SUCCESSFULLY constructed instance,
  // matching this file's existing convention for hardware-backed types.
  // `CMIOCameraBusyProvider.init` is different: it now resolves
  // `deviceUniqueID` and throws `.deviceNotFound` if nothing matches (see
  // that type's doc comment for why), which makes the not-found path a
  // genuine, deterministic behavior -- true on any machine, real camera
  // hardware or none, because "nonexistent-device-for-testing" is not a
  // real CMIO device UID -- so it IS tested for real below, not just
  // compiled. `CMIODeviceLookupTests` covers the pure matching logic this
  // check is built on.

  @Test("CMIOCameraBusyProvider conforms to CameraBusyProvider (metatype check, no construction)")
  func cmioBusyProviderConformsToProtocol() {
    // Proves the conformance compiles without needing a live/resolvable
    // device -- `init` now requires one (see below), so a metatype check
    // is the only construction-free way to assert this.
    let conformingType: any CameraBusyProvider.Type = CMIOCameraBusyProvider.self
    _ = conformingType
  }

  @Test("CMIOCameraBusyProvider.init throws .deviceNotFound for an unresolvable uniqueID")
  func cmioBusyProviderThrowsForUnresolvableDevice() {
    #expect(throws: CMIOCameraBusyProviderError.deviceNotFound("nonexistent-device-for-testing")) {
      try CMIOCameraBusyProvider(deviceUniqueID: "nonexistent-device-for-testing")
    }
  }

  @Test("The forcePolling initializer parameter does not bypass device resolution")
  func cmioBusyProviderForcePollingStillThrowsForUnresolvableDevice() {
    #expect(throws: CMIOCameraBusyProviderError.deviceNotFound("nonexistent-device-for-testing")) {
      try CMIOCameraBusyProvider(
        deviceUniqueID: "nonexistent-device-for-testing", pollIntervalSeconds: 2.0,
        forcePolling: true)
    }
  }

  @Test("CMIOAllDevicesBusyReader.currentRunningStates has the documented signature")
  func allDevicesBusyReaderSignatureCompiles() {
    let fn: () -> [CMIODeviceRunningState] = CMIOAllDevicesBusyReader.currentRunningStates
    _ = fn
  }

  @Test("CameraInUseMonitor's convenience device-ID init constructs without touching hardware")
  func monitorConvenienceInitConstructs() async {
    let monitor = CameraInUseMonitor(deviceUniqueID: "nonexistent-device-for-testing")
    #expect(await monitor.activePath == nil)
  }

  // `CameraMismatchMonitor` (§12.3's platform-probe layer) only touches
  // CoreMediaIO inside `start()`, via `CMIOAllDevicesBusyReader
  // .currentRunningStates()` — same hardware-backed category as everything
  // else in this file, so `start()`/`stop()` are never called here. `init`
  // only sets up an `AsyncStream` and touches no hardware, so it IS
  // constructed for real, matching this file's `CameraInUseMonitor`
  // convenience-init precedent immediately above.
  @Test("CameraMismatchMonitor constructs without touching CoreMediaIO")
  func mismatchMonitorConstructs() {
    let monitor = CameraMismatchMonitor()
    _ = monitor
  }

  // `CenterStageMonitor` (§12.5's app-side platform-probe layer) only
  // touches AVFoundation inside `start(uniqueID:intervalSeconds:)`, via
  // `CenterStageReader.read(forUniqueID:)` — the exact call this file's own
  // header says must never be exercised for real (see the long comment
  // above `centerStageReadForUniqueIDSignatureCompiles`: it opens a
  // `DiscoverySession` and hung CI for 45+ minutes, twice). So, same as
  // `CameraMismatchMonitor` above, only `init` is constructed for real here;
  // `start()`/`stop()` are never called.
  @Test("CenterStageMonitor constructs without touching AVFoundation")
  func centerStageMonitorConstructs() {
    let monitor = CenterStageMonitor()
    _ = monitor
  }

  @Test("PixelFormatCode renders a known four-character code")
  func pixelFormatCodeRendersKnownCode() {
    // kCVPixelFormatType_32BGRA == 'BGRA' as a four-character code.
    let code: UInt32 = 0x4247_5241
    #expect(PixelFormatCode.string(from: code) == "BGRA")
  }

  // `CenterStageReader.read(device:)` talks directly to an `AVCaptureDevice`
  // instance, so (like everything else CoreMediaIO/AVFoundation-backed in
  // this file) it is signature-only checked, never called. `currentSummaries()`
  // enumerates real hardware, so its *return count* is not asserted (varies
  // by machine) -- only that it has the documented signature, same
  // convention as `CMIOAllDevicesBusyReader.currentRunningStates` above.
  // `read(forUniqueID:)` is signature-only checked too, and MUST STAY THAT
  // WAY. It was briefly called for real (PR #66), on the reasoning that
  // "nonexistent-device-for-testing" cannot resolve on any machine, camera
  // hardware or none, so the assertion would be deterministic everywhere.
  // That reasoning is true about the RESULT and wrong about the COST: to
  // discover that nothing matches, the call still opens an
  // `AVCaptureDevice.DiscoverySession` and enumerates every capture device.
  // On CI's headless runner that enumeration blocks -- it hung
  // `swift test` for 45+ minutes, twice consecutively, on a docs-only PR,
  // after passing once (2026-08-05). Intermittent, because it depends on
  // whether the runner's camera daemon answers at all.
  //
  // This is exactly the rule in this file's own header, and in CLAUDE.md:
  // never write a test that requires a live camera to pass in CI. A test
  // that only READS "no devices" still has to ask the hardware. The
  // `.deviceNotFound` semantics that test meant to pin are covered purely,
  // with no AVFoundation involvement, by `CenterStageDeviceReadingTests`.

  @Test("CenterStageReader.read(device:) has the documented signature")
  func centerStageReadDeviceSignatureCompiles() {
    let fn: (AVCaptureDevice) -> CenterStageReading = CenterStageReader.read(device:)
    _ = fn
  }

  @Test("CenterStageReader.currentSummaries has the documented signature")
  func centerStageCurrentSummariesSignatureCompiles() {
    let fn: () -> [CenterStageDeviceSummary] = CenterStageReader.currentSummaries
    _ = fn
  }

  @Test("CenterStageReader.read(forUniqueID:) has the documented signature")
  func centerStageReadForUniqueIDSignatureCompiles() {
    let fn: (String) -> CenterStageDeviceReading = CenterStageReader.read(forUniqueID:)
    _ = fn
  }
}

/// `CameraSessionPreset` (the fix for the production bug `probe-camera`
/// found — see that type's doc comment): maps the exact sizes the spec ever
/// requests to a concrete `AVCaptureSession.Preset`, and returns `nil` for
/// anything else. Pure mapping logic, no session/device involved, so no
/// live camera is needed to test it.
struct CameraSessionPresetTests {
  @Test("640x480 (§5.2 Monitor) maps to .vga640x480")
  func vga640x480() {
    #expect(CameraSessionPreset.preset(forWidth: 640, height: 480) == .vga640x480)
  }

  @Test("1280x720 (§5.1 Setup) maps to .hd1280x720")
  func hd1280x720() {
    #expect(CameraSessionPreset.preset(forWidth: 1280, height: 720) == .hd1280x720)
  }

  @Test("1920x1080 maps to .hd1920x1080")
  func hd1920x1080() {
    #expect(CameraSessionPreset.preset(forWidth: 1920, height: 1080) == .hd1920x1080)
  }

  @Test("An unmapped size returns nil")
  func unmappedSizeReturnsNil() {
    #expect(CameraSessionPreset.preset(forWidth: 800, height: 600) == nil)
    #expect(CameraSessionPreset.preset(forWidth: 0, height: 0) == nil)
  }
}
