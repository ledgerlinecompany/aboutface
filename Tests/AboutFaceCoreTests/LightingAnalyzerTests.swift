import CoreGraphics
import CoreVideo
import Testing

@testable import AboutFaceCore

// MARK: - Synthetic buffer helpers

/// A single BGRA8 pixel value, used instead of a 4-tuple to stay within
/// SwiftLint's tuple-arity limit.
private struct BGRA {
  let b: UInt8
  let g: UInt8
  let r: UInt8
  let a: UInt8

  init(_ b: UInt8, _ g: UInt8, _ r: UInt8, _ a: UInt8 = 255) {
    self.b = b
    self.g = g
    self.r = r
    self.a = a
  }
}

/// A BGR triple (no alpha), for describing a fill region's color.
private struct BGR {
  let b: UInt8
  let g: UInt8
  let r: UInt8
}

/// Builds a `kCVPixelFormatType_32BGRA` pixel buffer, calling `fill` once per
/// pixel to obtain its color. `fill`'s `row` is top-row-first (row 0 is the
/// top of the image), matching `LightingAnalyzer`'s internal `PixelGrid`
/// convention.
private func makePixelBuffer(
  width: Int,
  height: Int,
  fill: (_ row: Int, _ col: Int) -> BGRA
) -> CVPixelBuffer {
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
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
  let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

  for row in 0..<height {
    let rowBase = row * rowBytes
    for col in 0..<width {
      let pixel = fill(row, col)
      let idx = rowBase + col * 4
      base[idx] = pixel.b
      base[idx + 1] = pixel.g
      base[idx + 2] = pixel.r
      base[idx + 3] = pixel.a
    }
  }
  return buffer
}

private func uniformBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer {
  makePixelBuffer(width: width, height: height) { _, _ in BGRA(gray, gray, gray) }
}

/// Left half (`col < width / 2`) pure black, right half pure white.
private func halfBlackHalfWhiteBuffer(width: Int, height: Int) -> CVPixelBuffer {
  makePixelBuffer(width: width, height: height) { _, col in
    col < width / 2 ? BGRA(0, 0, 0) : BGRA(255, 255, 255)
  }
}

/// Single-pixel checkerboard: maximal high-frequency content for sharpness
/// testing.
private func checkerboardBuffer(width: Int, height: Int) -> CVPixelBuffer {
  makePixelBuffer(width: width, height: height) { row, col in
    (row + col).isMultiple(of: 2) ? BGRA(255, 255, 255) : BGRA(0, 0, 0)
  }
}

/// A frame with a uniform `background` gray everywhere except a rectangular
/// `region` (top-row-first pixel row/col ranges) filled with a
/// caller-supplied BGR color.
private func regionBuffer(
  width: Int,
  height: Int,
  background: UInt8,
  region: (rows: Range<Int>, cols: Range<Int>),
  regionColor: BGR
) -> CVPixelBuffer {
  makePixelBuffer(width: width, height: height) { row, col in
    if region.rows.contains(row) && region.cols.contains(col) {
      return BGRA(regionColor.b, regionColor.g, regionColor.r)
    }
    return BGRA(background, background, background)
  }
}

/// Converts top-row-first pixel row/col ranges into the normalized,
/// bottom-left-origin ROI rect `LightingAnalyzer` expects (Vision raw
/// space) — the exact inverse of the analyzer's internal `pixelRegion(for:)`
/// math, so ROIs constructed this way land on exact grid boundaries with no
/// rounding slop.
private func roiRect(rows: Range<Int>, cols: Range<Int>, width: Int, height: Int) -> CGRect {
  let minX = Double(cols.lowerBound) / Double(width)
  let maxX = Double(cols.upperBound) / Double(width)
  let minY = 1 - Double(rows.upperBound) / Double(height)
  let maxY = 1 - Double(rows.lowerBound) / Double(height)
  return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// A config whose `lighting.maxAnalysisWidth` is large enough that the given
/// frame is never downsampled, isolating tests that care about exact
/// full-resolution arithmetic from the downsampling path.
private func noDownsampleConfig(width: Int) -> Config {
  var config = Config.defaults
  config.lighting.maxAnalysisWidth = width
  return config
}

private func luma(ofGray gray: UInt8) -> Float {
  Float(gray) / 255
}

// MARK: - Tests

struct LightingAnalyzerTests {

  @Test("Uniform mid-gray frame: exact luma, ~0 variance, no clipping, ~0 sharpness")
  func uniformFrame() throws {
    let width = 64
    let height = 64
    let gray: UInt8 = 128
    let buffer = uniformBuffer(width: width, height: height, gray: gray)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: nil, config: config)

    let expectedLuma = luma(ofGray: gray)
    #expect(metrics.faceLuma == 0)  // no ROI supplied
    #expect(abs(metrics.backgroundLuma - expectedLuma) < 0.001)
    #expect(abs(metrics.backlightDelta - expectedLuma) < 0.001)
    #expect(metrics.frameLumaVariance < 1e-6)
    #expect(metrics.clippedHighlightFraction == 0)
    #expect(metrics.clippedShadowFraction == 0)
    #expect(abs(metrics.sharpness) < 1e-6)
  }

  @Test("Half black / half white frame: ~0.5 luma, ~0.5 clipped fractions each, high variance")
  func halfBlackHalfWhite() throws {
    let width = 64
    let height = 64
    let buffer = halfBlackHalfWhiteBuffer(width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: nil, config: config)

    #expect(abs(metrics.backgroundLuma - 0.5) < 0.01)
    #expect(abs(metrics.clippedHighlightFraction - 0.5) < 0.01)
    #expect(abs(metrics.clippedShadowFraction - 0.5) < 0.01)
    #expect(metrics.frameLumaVariance > 0.2)  // exact split gives 0.25
  }

  @Test("Face ROI brighter than background produces negative backlightDelta")
  func brightFaceROI() throws {
    let width = 100
    let height = 100
    let rows = 20..<50
    let cols = 30..<70
    let buffer = regionBuffer(
      width: width,
      height: height,
      background: 50,
      region: (rows: rows, cols: cols),
      regionColor: BGR(b: 200, g: 200, r: 200)
    )
    let roi = roiRect(rows: rows, cols: cols, width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: roi, config: config)

    #expect(metrics.faceLuma > metrics.backgroundLuma)
    #expect(metrics.backlightDelta < 0)
  }

  @Test("Face ROI darker than background (backlit) produces positive backlightDelta")
  func darkFaceROI() throws {
    let width = 100
    let height = 100
    let rows = 20..<50
    let cols = 30..<70
    let buffer = regionBuffer(
      width: width,
      height: height,
      background: 200,
      region: (rows: rows, cols: cols),
      regionColor: BGR(b: 50, g: 50, r: 50)
    )
    let roi = roiRect(rows: rows, cols: cols, width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: roi, config: config)

    #expect(metrics.faceLuma < metrics.backgroundLuma)
    #expect(metrics.backlightDelta > 0)
  }

  @Test("Warm (red-heavy) face ROI gives positive colorTempSkew, bounded in [-1, 1]")
  func warmColorTemp() throws {
    let width = 100
    let height = 100
    let rows = 20..<50
    let cols = 30..<70
    let buffer = regionBuffer(
      width: width,
      height: height,
      background: 128,
      region: (rows: rows, cols: cols),
      regionColor: BGR(b: 30, g: 100, r: 220)
    )
    let roi = roiRect(rows: rows, cols: cols, width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: roi, config: config)

    #expect(metrics.colorTempSkew > 0)
    #expect(metrics.colorTempSkew <= 1)
    #expect(metrics.colorTempSkew >= -1)
  }

  @Test("Cool (blue-heavy) face ROI gives negative colorTempSkew, bounded in [-1, 1]")
  func coolColorTemp() throws {
    let width = 100
    let height = 100
    let rows = 20..<50
    let cols = 30..<70
    let buffer = regionBuffer(
      width: width,
      height: height,
      background: 128,
      region: (rows: rows, cols: cols),
      regionColor: BGR(b: 220, g: 100, r: 30)
    )
    let roi = roiRect(rows: rows, cols: cols, width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: roi, config: config)

    #expect(metrics.colorTempSkew < 0)
    #expect(metrics.colorTempSkew <= 1)
    #expect(metrics.colorTempSkew >= -1)
  }

  @Test("Neutral gray face ROI gives colorTempSkew ~0")
  func neutralColorTemp() throws {
    let width = 100
    let height = 100
    let buffer = uniformBuffer(width: width, height: height, gray: 128)
    let roi = roiRect(rows: 20..<50, cols: 30..<70, width: width, height: height)
    let config = noDownsampleConfig(width: width)

    let metrics = try LightingAnalyzer.analyze(pixelBuffer: buffer, faceROI: roi, config: config)

    #expect(abs(metrics.colorTempSkew) < 0.01)
  }

  @Test("Checkerboard sharpness is far greater than uniform sharpness")
  func checkerboardIsSharperThanUniform() throws {
    let width = 64
    let height = 64
    let config = noDownsampleConfig(width: width)

    let checkerboard = checkerboardBuffer(width: width, height: height)
    let uniform = uniformBuffer(width: width, height: height, gray: 128)

    let checkerboardMetrics = try LightingAnalyzer.analyze(
      pixelBuffer: checkerboard,
      faceROI: nil,
      config: config
    )
    let uniformMetrics = try LightingAnalyzer.analyze(
      pixelBuffer: uniform,
      faceROI: nil,
      config: config
    )

    #expect(uniformMetrics.sharpness < 1e-6)
    #expect(checkerboardMetrics.sharpness > uniformMetrics.sharpness * 1000)
  }

  @Test("Unsupported pixel format throws")
  func unsupportedPixelFormat() throws {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      16,
      16,
      kCVPixelFormatType_32ARGB,
      nil,
      &pixelBuffer
    )
    precondition(status == kCVReturnSuccess)

    #expect(throws: LightingAnalyzer.AnalyzerError.self) {
      try LightingAnalyzer.analyze(pixelBuffer: pixelBuffer!, faceROI: nil, config: Config.defaults)
    }
  }

  // MARK: - Downsampling agreement

  @Test("Downsampled uniform frame agrees with full-resolution analysis")
  func downsampledUniformAgreesWithFullRes() throws {
    let width = 640
    let height = 360
    let gray: UInt8 = 160
    let buffer = uniformBuffer(width: width, height: height, gray: gray)

    let fullRes = try LightingAnalyzer.analyze(
      pixelBuffer: buffer,
      faceROI: nil,
      config: noDownsampleConfig(width: width)
    )
    // Config.defaults.lighting.maxAnalysisWidth (320) forces downsampling
    // for a 640-wide source.
    let downsampled = try LightingAnalyzer.analyze(
      pixelBuffer: buffer,
      faceROI: nil,
      config: .defaults
    )

    #expect(abs(fullRes.backgroundLuma - downsampled.backgroundLuma) < 0.01)
    #expect(abs(fullRes.frameLumaVariance - downsampled.frameLumaVariance) < 0.01)
    #expect(abs(fullRes.clippedHighlightFraction - downsampled.clippedHighlightFraction) < 0.01)
    #expect(abs(fullRes.clippedShadowFraction - downsampled.clippedShadowFraction) < 0.01)
  }

  @Test("Downsampled half black/half white frame agrees with full-resolution analysis")
  func downsampledHalfBlackHalfWhiteAgreesWithFullRes() throws {
    let width = 640
    let height = 360
    let buffer = halfBlackHalfWhiteBuffer(width: width, height: height)

    let fullRes = try LightingAnalyzer.analyze(
      pixelBuffer: buffer,
      faceROI: nil,
      config: noDownsampleConfig(width: width)
    )
    let downsampled = try LightingAnalyzer.analyze(
      pixelBuffer: buffer,
      faceROI: nil,
      config: .defaults
    )

    #expect(abs(fullRes.backgroundLuma - downsampled.backgroundLuma) < 0.02)
    #expect(abs(fullRes.clippedHighlightFraction - downsampled.clippedHighlightFraction) < 0.03)
    #expect(abs(fullRes.clippedShadowFraction - downsampled.clippedShadowFraction) < 0.03)
    #expect(downsampled.frameLumaVariance > 0.2)
  }
}
