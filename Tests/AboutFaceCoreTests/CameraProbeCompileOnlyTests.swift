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

  @Test("CameraInUseMonitor's convenience device-ID init constructs without touching hardware")
  func monitorConvenienceInitConstructs() async {
    let monitor = CameraInUseMonitor(deviceUniqueID: "nonexistent-device-for-testing")
    #expect(await monitor.activePath == nil)
  }

  @Test("PixelFormatCode renders a known four-character code")
  func pixelFormatCodeRendersKnownCode() {
    // kCVPixelFormatType_32BGRA == 'BGRA' as a four-character code.
    let code: UInt32 = 0x4247_5241
    #expect(PixelFormatCode.string(from: code) == "BGRA")
  }
}
