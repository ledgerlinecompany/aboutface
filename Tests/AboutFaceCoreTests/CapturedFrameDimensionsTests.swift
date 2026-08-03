import CoreGraphics
import CoreMedia
import Testing

@testable import AboutFaceCore

/// `CapturedFrame.pixelDimensions` and `EngineOutput.capturedPixelDimensions`
/// (the "actual delivered format" plumbing added alongside Monitor mode's
/// capture-format work): the ACTUAL pixel dimensions read off a real
/// `CVPixelBuffer`, threaded through `AnalysisEngine.process(_:)` on every
/// `EngineOutput` it produces — live or nil-face — not just parroting back
/// whatever width/height a capture session was configured to request (PR
/// #53's lesson: a request is not proof of what was delivered).
struct CapturedFrameDimensionsTests {

  @Test("CapturedFrame.pixelDimensions reads the real CVPixelBuffer's width/height")
  func pixelDimensions_matchesRealBuffer() {
    let frame = testFrame(
      pixelBuffer: uniformPixelBuffer(width: 96, height: 64), mirror: .notMirrored)
    #expect(frame.pixelDimensions == PixelDimensions(width: 96, height: 64))
  }

  @Test("process(_:) sets capturedPixelDimensions on the no-face path")
  func process_noFace_setsCapturedPixelDimensions() async throws {
    let engine = AnalysisEngine(backend: ScriptedBackend([nil]))
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(width: 48, height: 32), mirror: .notMirrored))
    #expect(output.analysis.primary == nil)
    #expect(output.capturedPixelDimensions == PixelDimensions(width: 48, height: 32))
  }

  @Test("process(_:) sets capturedPixelDimensions on the detected-face path")
  func process_faceDetected_setsCapturedPixelDimensions() async throws {
    let raw = RawFaceObservation(
      boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
      eyePoints: [CGPoint(x: 0.48, y: 0.55), CGPoint(x: 0.52, y: 0.55)],
      yaw: 0, pitch: 0, roll: 0,
      confidence: 0.9,
      faceCount: 1
    )
    let engine = AnalysisEngine(backend: ScriptedBackend([raw]))
    let output = try await engine.process(
      testFrame(pixelBuffer: gradientPixelBuffer(width: 80, height: 60), mirror: .notMirrored))
    #expect(output.analysis.primary != nil)
    #expect(output.capturedPixelDimensions == PixelDimensions(width: 80, height: 60))
  }

  @Test("Hand-built EngineOutput fixtures (not routed through process(_:)) default to nil")
  func handBuiltEngineOutput_defaultsToNilCapturedPixelDimensions() {
    let analysis = FrameAnalysis(
      timestamp: .zero, signalState: .noFace, faceCount: 0, primary: nil,
      lighting: LightingMetrics(
        faceLuma: 0, backgroundLuma: 0, backlightDelta: 0, clippedHighlightFraction: 0,
        clippedShadowFraction: 0, colorTempSkew: 0, sharpness: 0, frameLumaVariance: 0))
    let output = EngineOutput(analysis: analysis, framing: nil)
    #expect(output.capturedPixelDimensions == nil)
  }
}
