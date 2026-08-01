import Accelerate
import CoreVideo

/// Downsampling: turns a raw `CVPixelBuffer` into the small, tightly-packed
/// `PixelGrid` that `LightingAnalyzerMath.swift`'s region/statistics code
/// operates on. Split into its own file purely to keep each file a
/// manageable size; see `LightingAnalyzer.swift` for the type's documented
/// behavior, including the performance rationale for downsampling at all.
extension LightingAnalyzer {

  /// Downsamples `pixelBuffer` (already locked by the caller) to at most
  /// `maxWidth` pixels wide, preserving aspect ratio, and decomposes it into
  /// a `PixelGrid`. If the source is already at or under `maxWidth`, no
  /// resampling happens — the buffer is read directly into a tightly packed
  /// grid, avoiding any interpolation that could perturb exact-value tests.
  static func downsampledGrid(pixelBuffer: CVPixelBuffer, maxWidth: Int) throws -> PixelGrid {
    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw AnalyzerError.noBaseAddress
    }

    if maxWidth <= 0 || srcWidth <= maxWidth {
      return buildGrid(data: srcBase, width: srcWidth, height: srcHeight, bytesPerRow: srcRowBytes)
    }

    return try downscaledGrid(
      srcBase: srcBase,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      srcRowBytes: srcRowBytes,
      maxWidth: maxWidth
    )
  }

  private static func downscaledGrid(
    srcBase: UnsafeMutableRawPointer,
    srcWidth: Int,
    srcHeight: Int,
    srcRowBytes: Int,
    maxWidth: Int
  ) throws -> PixelGrid {
    let scale = Double(maxWidth) / Double(srcWidth)
    let dstWidth = max(1, Int((Double(srcWidth) * scale).rounded()))
    let dstHeight = max(1, Int((Double(srcHeight) * scale).rounded()))
    let dstRowBytes = dstWidth * 4

    var srcBuffer = vImage_Buffer(
      data: srcBase,
      height: vImagePixelCount(srcHeight),
      width: vImagePixelCount(srcWidth),
      rowBytes: srcRowBytes
    )

    var dstData = [UInt8](repeating: 0, count: dstHeight * dstRowBytes)
    let error: vImage_Error = dstData.withUnsafeMutableBytes { rawPtr in
      var dstBuffer = vImage_Buffer(
        data: rawPtr.baseAddress,
        height: vImagePixelCount(dstHeight),
        width: vImagePixelCount(dstWidth),
        rowBytes: dstRowBytes
      )
      return vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
    }
    guard error == kvImageNoError else {
      throw AnalyzerError.downsampleFailed(error)
    }

    return dstData.withUnsafeBytes { rawPtr in
      buildGrid(
        data: rawPtr.baseAddress!,
        width: dstWidth,
        height: dstHeight,
        bytesPerRow: dstRowBytes
      )
    }
  }

  /// Decomposes a tightly-addressable BGRA8 buffer into a `PixelGrid`. This
  /// is the one place per-pixel Swift code runs, and it only ever runs over
  /// the already-downsampled buffer (at most `maxWidth` pixels wide), never
  /// the full-resolution source.
  private static func buildGrid(
    data: UnsafeRawPointer,
    width: Int,
    height: Int,
    bytesPerRow: Int
  ) -> PixelGrid {
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var luma = [Float](repeating: 0, count: width * height)
    var red = [Float](repeating: 0, count: width * height)
    var blue = [Float](repeating: 0, count: width * height)

    for row in 0..<height {
      let rowBase = row * bytesPerRow
      let outBase = row * width
      for col in 0..<width {
        let pixelBase = rowBase + col * 4
        // kCVPixelFormatType_32BGRA byte order: B, G, R, A.
        let b = Float(bytes[pixelBase]) / 255
        let g = Float(bytes[pixelBase + 1]) / 255
        let r = Float(bytes[pixelBase + 2]) / 255
        let idx = outBase + col
        luma[idx] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        red[idx] = r
        blue[idx] = b
      }
    }
    return PixelGrid(width: width, height: height, luma: luma, red: red, blue: blue)
  }
}
