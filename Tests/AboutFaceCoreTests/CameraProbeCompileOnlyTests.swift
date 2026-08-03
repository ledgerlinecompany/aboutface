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
