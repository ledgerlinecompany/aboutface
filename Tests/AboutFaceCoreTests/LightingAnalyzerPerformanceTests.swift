import CoreVideo
import Testing

@testable import AboutFaceCore

/// Measures (and prints) `LightingAnalyzer`'s per-frame cost against a
/// realistic 720p input, referenced from `LightingAnalyzer`'s type-level
/// doc comment. This is informational only — per the task's own performance
/// note, CI hardware varies, so the timing is printed rather than asserted
/// on. Correctness of the downsample-then-analyze pipeline itself is covered
/// by `LightingAnalyzerTests`'s downsampling-agreement tests.
struct LightingAnalyzerPerformanceTests {

  @Test("Single analyze() call on a 720p frame, timed and printed")
  func measureSingleFrameCost() throws {
    let width = 1280
    let height = 720

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    precondition(status == kCVReturnSuccess, "Failed to create test CVPixelBuffer")
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      let bytes = base.assumingMemoryBound(to: UInt8.self)
      // A checkerboard-ish fill is a reasonably representative worst case
      // for the Laplacian pass (uniform frames short-circuit to all-zero
      // responses and would understate real cost).
      for row in 0..<height {
        let rowBase = row * rowBytes
        for col in 0..<width {
          let value: UInt8 = (row ^ col) & 0xFF == 0 ? 255 : 96
          let idx = rowBase + col * 4
          bytes[idx] = value
          bytes[idx + 1] = value
          bytes[idx + 2] = value
          bytes[idx + 3] = 255
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    // Warm up (allocations, cache effects) before timing.
    _ = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: nil, config: .defaults)

    let iterations = 20
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for _ in 0..<iterations {
        _ = try? LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: nil, config: .defaults)
      }
    }
    let perCall = elapsed / iterations
    let analysisWidth = Config.defaults.lighting.maxAnalysisWidth
    print(
      "LightingAnalyzer.analyze(): \(perCall) per call over \(iterations) iterations "
        + "on a \(width)x\(height) frame (maxAnalysisWidth=\(analysisWidth))."
    )

    // No assertion on the measured duration itself — see the type doc
    // comment on `LightingAnalyzer` and this file's own doc comment.
  }
}
