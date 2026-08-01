import CoreGraphics
import Testing

@testable import AboutFaceCore

struct AnalysisEngineSignalStateTests {

  @Test("Uniform frame classifies as .noSignal, regardless of backend output")
  func uniformFrame_noSignal() async throws {
    let engine = AnalysisEngine(backend: ScriptedBackend([nil]))
    let output = try await engine.process(
      testFrame(pixelBuffer: uniformPixelBuffer(), mirror: .notMirrored))
    #expect(output.analysis.signalState == .noSignal)
    #expect(output.analysis.primary == nil)
    #expect(output.framing == nil)
  }

  @Test("Low-confidence observation on a normal frame classifies as .lowConfidence")
  func lowConfidence() async throws {
    let raw = RawFaceObservation(
      boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
      eyePoints: [CGPoint(x: 0.48, y: 0.55), CGPoint(x: 0.52, y: 0.55)],
      yaw: 0, pitch: 0, roll: 0,
      // Config.defaults.signal.lowConfidenceThreshold == 0.5.
      confidence: 0.2,
      faceCount: 1
    )
    let engine = AnalysisEngine(backend: ScriptedBackend([raw]))
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    #expect(output.analysis.signalState == .lowConfidence)
  }

  @Test("No face on a normal (non-uniform) frame classifies as .noFace")
  func noFace() async throws {
    let engine = AnalysisEngine(backend: ScriptedBackend([nil]))
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(), mirror: .notMirrored))
    #expect(output.analysis.signalState == .noFace)
  }
}
