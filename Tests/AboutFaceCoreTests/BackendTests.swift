import CoreGraphics
import CoreMedia
import CoreVideo
import Testing

@testable import AboutFaceCore

private func allCapabilityFlags() -> [BackendCapabilities] {
  [.headPose, .gaze, .metricDistance, .captureQuality, .multiFace]
}

struct BackendCapabilitiesTests {

  @Test("Individual flags are distinct bits")
  func distinctBits() {
    let all = allCapabilityFlags()
    for (i, a) in all.enumerated() {
      for (j, b) in all.enumerated() where i != j {
        #expect(!a.contains(b))
      }
    }
  }

  @Test("Union combines flags and contains() reports membership")
  func unionAndContains() {
    let combo: BackendCapabilities = [.captureQuality, .multiFace, .headPose]

    #expect(combo.contains(.captureQuality))
    #expect(combo.contains(.multiFace))
    #expect(combo.contains(.headPose))
    #expect(!combo.contains(.gaze))
    #expect(!combo.contains(.metricDistance))
  }

  @Test("Empty set contains nothing")
  func emptySet() {
    let empty: BackendCapabilities = []
    #expect(!empty.contains(.headPose))
    #expect(!empty.contains(.gaze))
  }

  @Test("Subtracting a flag removes only that flag")
  func subtracting() {
    let combo: BackendCapabilities = [.captureQuality, .multiFace, .headPose]
    let reduced = combo.subtracting(.multiFace)

    #expect(reduced.contains(.captureQuality))
    #expect(reduced.contains(.headPose))
    #expect(!reduced.contains(.multiFace))
  }

  @Test("Insert and remove behave like a standard OptionSet")
  func insertAndRemove() {
    var caps: BackendCapabilities = []
    caps.insert(.gaze)
    #expect(caps.contains(.gaze))

    caps.remove(.gaze)
    #expect(!caps.contains(.gaze))
  }
}

struct VisionBackendTests {

  @Test("Reports the expected static identity")
  func staticIdentity() {
    #expect(VisionBackend.identifier == "vision")
    #expect(VisionBackend.displayName == "Apple Vision")
    #expect(VisionBackend.isAvailable == true)
  }

  @Test("Declares captureQuality, multiFace, and headPose capabilities")
  func declaredCapabilities() {
    let backend = VisionBackend()
    #expect(backend.capabilities.contains(.captureQuality))
    #expect(backend.capabilities.contains(.multiFace))
    #expect(backend.capabilities.contains(.headPose))
    #expect(!backend.capabilities.contains(.gaze))
    #expect(!backend.capabilities.contains(.metricDistance))
  }

  @Test("analyze() returns nil (Phase 1 scaffolding, no real inference yet)")
  func analyzeReturnsNil() async throws {
    let backend = VisionBackend()
    let frame = try Self.makeDummyFrame()

    let result = try await backend.analyze(frame)
    #expect(result == nil)
  }

  /// Builds a minimal 2x2 BGRA `CapturedFrame` for exercising the backend
  /// protocol shape. Contents are irrelevant since the stub never inspects
  /// the pixel buffer.
  private static func makeDummyFrame() throws -> CapturedFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      2,
      2,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    precondition(status == kCVReturnSuccess, "Failed to create test CVPixelBuffer")

    return CapturedFrame(
      pixelBuffer: pixelBuffer!,
      timestamp: CMTime(value: 0, timescale: 600),
      mirrorState: .notMirrored
    )
  }
}
