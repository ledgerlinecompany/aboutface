import CoreGraphics
import CoreMedia
import CoreVideo
import Testing

@testable import AboutFaceCore

// MARK: - Scripted mock backend

/// A test-only `FaceAnalysisBackend` that returns a pre-scripted sequence of
/// `RawFaceObservation?` values, one per call to `analyze(_:)`, in order.
/// Lets the various `AnalysisEngine*Tests` suites (split across files
/// purely to stay under SwiftLint's file-length limit; this file holds the
/// shared support they all use, `internal` rather than `private` so it is
/// visible across those files within this single test target) drive
/// `AnalysisEngine` deterministically without Vision inference or real
/// pixel content mattering for the geometry path — only `LightingAnalyzer`
/// (run for real, on synthetic pixel buffers built per test) reads actual
/// pixel data.
///
/// An actor (not a plain class) purely so `index` mutation is safe under
/// Swift 6 strict concurrency without a manual lock — `analyze(_:)` is
/// already `async`, so actor-isolating it costs nothing at call sites.
actor ScriptedBackend: FaceAnalysisBackend {
  static let identifier = "scripted-mock"
  static let displayName = "Scripted Mock"
  static let isAvailable = true

  let capabilities: BackendCapabilities = [.headPose, .captureQuality]

  private var script: [RawFaceObservation?]
  private var index = 0

  init(_ script: [RawFaceObservation?]) {
    self.script = script
  }

  func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation? {
    guard index < script.count else { return nil }
    defer { index += 1 }
    return script[index]
  }
}

// MARK: - Synthetic pixel buffers

/// A single BGR pixel value, used instead of a 3-tuple to stay within
/// SwiftLint's tuple-arity limit (same reasoning as `BackendTests.swift`'s
/// `BGRAPixel`).
struct TestRGB {
  let r: UInt8
  let g: UInt8
  let b: UInt8
}

/// Builds a `kCVPixelFormatType_32BGRA` pixel buffer filled with a single
/// uniform gray value. Uniform content gives `LightingMetrics.frameLumaVariance`
/// ~0, which is exactly what `.noSignal` classification needs to trigger,
/// and (away from `.noSignal`'s threshold) gives a stable, predictable
/// `faceLuma`/`backgroundLuma` for tests that don't care about lighting
/// specifically.
func uniformPixelBuffer(width: Int = 32, height: Int = 32, gray: UInt8 = 128) -> CVPixelBuffer {
  makeTestPixelBuffer(width: width, height: height) { _, _ in TestRGB(r: gray, g: gray, b: gray) }
}

/// Builds a `kCVPixelFormatType_32BGRA` pixel buffer with a horizontal
/// gradient, giving `LightingMetrics.frameLumaVariance` comfortably above
/// `Config.defaults.signal.noSignalLumaVarianceThreshold` — used by tests
/// that need a "normal" (non-uniform) frame so `.noSignal` does not mask
/// the classification actually under test.
func gradientPixelBuffer(width: Int = 32, height: Int = 32) -> CVPixelBuffer {
  makeTestPixelBuffer(width: width, height: height) { x, _ in
    let value = UInt8((x * 255) / max(width - 1, 1))
    return TestRGB(r: value, g: value, b: value)
  }
}

func makeTestPixelBuffer(
  width: Int,
  height: Int,
  pixel: (_ x: Int, _ y: Int) -> TestRGB
) -> CVPixelBuffer {
  var pixelBufferOrNil: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBufferOrNil)
  precondition(status == kCVReturnSuccess, "Failed to create test CVPixelBuffer")
  let buffer = pixelBufferOrNil!

  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
  let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

  for y in 0..<height {
    let rowBase = y * bytesPerRow
    for x in 0..<width {
      let color = pixel(x, y)
      let offset = rowBase + x * 4
      base[offset + 0] = color.b
      base[offset + 1] = color.g
      base[offset + 2] = color.r
      base[offset + 3] = 255
    }
  }
  return buffer
}

func testFrame(
  pixelBuffer: CVPixelBuffer,
  mirror: MirrorState,
  frameIndex: Int = 0
) -> CapturedFrame {
  CapturedFrame(
    pixelBuffer: pixelBuffer,
    timestamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
    mirrorState: mirror
  )
}
