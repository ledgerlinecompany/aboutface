import Accelerate
import CoreGraphics

/// Region geometry and statistics backing
/// `LightingAnalyzer.analyze(pixelBuffer:faceROI:config:)`. Split out of
/// `LightingAnalyzer.swift` (and out of `LightingAnalyzerDownsample.swift`,
/// which turns a raw `CVPixelBuffer` into the `PixelGrid` this file works
/// on) purely to keep each file a manageable size; everything here is still
/// `LightingAnalyzer`'s private implementation, not a separate public
/// surface. See `LightingAnalyzer.swift` for the type's documented behavior
/// and coordinate-space contract.
extension LightingAnalyzer {

  // MARK: - Grid and region types

  /// A downsampled BGRA frame, pre-decomposed into per-pixel luma (Rec.709)
  /// and red/blue channel arrays, row-major, top-row-first.
  struct PixelGrid {
    let width: Int
    let height: Int
    let luma: [Float]
    let red: [Float]
    let blue: [Float]
  }

  /// A half-open pixel-space rectangle in a `PixelGrid`, top-row-first.
  struct Region {
    let rowRange: Range<Int>
    let colRange: Range<Int>
  }

  /// The regions `analyze(pixelBuffer:faceROI:config:)` needs: the whole
  /// frame, the face ROI converted to pixel space (if any and non-empty),
  /// and which region colorTempSkew/sharpness should sample (the ROI when
  /// available, the whole frame otherwise).
  struct RegionSet {
    let wholeFrame: Region
    let roi: Region?
    let hasNonEmptyROI: Bool
    let sample: Region
  }

  /// `LightingMetrics`' exposure-related fields.
  struct ExposureMetrics {
    let faceLuma: Float
    let backgroundLuma: Float
    let frameLumaVariance: Float
    let clippedHighlightFraction: Float
    let clippedShadowFraction: Float
  }

  /// `LightingMetrics`' color/sharpness fields.
  struct ColorAndSharpness {
    let colorTempSkew: Float
    let sharpness: Float
  }

  /// Numerical division-by-zero guard for `colorTempSkew`; see the comment
  /// at its use site in `colorAndSharpnessMetrics`.
  static let colorEpsilon: Float = 1e-6

  // MARK: - Orchestration

  static func regionSet(grid: PixelGrid, faceROI: CGRect?) -> RegionSet {
    let wholeFrame = Region(rowRange: 0..<grid.height, colRange: 0..<grid.width)
    let roi = faceROI.map { pixelRegion(for: $0, width: grid.width, height: grid.height) }
    let hasNonEmptyROI = roi.map { !$0.rowRange.isEmpty && !$0.colRange.isEmpty } ?? false
    let sample = hasNonEmptyROI ? (roi ?? wholeFrame) : wholeFrame
    return RegionSet(
      wholeFrame: wholeFrame,
      roi: roi,
      hasNonEmptyROI: hasNonEmptyROI,
      sample: sample
    )
  }

  /// - `faceLuma` is documented (§3.3) as "mean luma, face ROI" — with no
  ///   ROI there is nothing to sample, so it is reported as 0 rather than
  ///   falling back to a whole-frame value. Do not read 0 as "totally
  ///   dark"; it means "no face region was supplied this frame."
  /// - `backgroundLuma` falls back to the whole-frame mean in the
  ///   degenerate case where the ROI covers the entire downsampled frame
  ///   and there is no background left to sample.
  /// - Clipping is measured over the whole frame, not just the face ROI: a
  ///   blown-out window behind the subject or a black background
  ///   swallowing shadow detail are both exposure problems worth surfacing
  ///   even when the face itself is well exposed.
  static func exposureMetrics(
    grid: PixelGrid,
    regions: RegionSet,
    config: Config
  ) -> ExposureMetrics {
    let (frameLumaMean, frameLumaVariance) = meanAndVariance(grid.luma)

    let faceLuma: Float
    let backgroundLuma: Float
    if regions.hasNonEmptyROI, let roi = regions.roi {
      faceLuma = mean(grid.luma, width: grid.width, region: roi).mean
      let background = meanExcluding(grid.luma, width: grid.width, height: grid.height, region: roi)
      backgroundLuma = background.total > 0 ? background.mean : frameLumaMean
    } else {
      faceLuma = 0
      backgroundLuma = frameLumaMean
    }

    let clippedHighlightFraction = clippedFraction(
      grid.luma,
      threshold: Float(config.lighting.clippedHighlightThreshold),
      isHighlight: true
    )
    let clippedShadowFraction = clippedFraction(
      grid.luma,
      threshold: Float(config.lighting.clippedShadowThreshold),
      isHighlight: false
    )

    return ExposureMetrics(
      faceLuma: faceLuma,
      backgroundLuma: backgroundLuma,
      frameLumaVariance: frameLumaVariance,
      clippedHighlightFraction: clippedHighlightFraction,
      clippedShadowFraction: clippedShadowFraction
    )
  }

  /// colorTempSkew and sharpness both sample the face ROI when available,
  /// falling back to the whole frame when there is no face to focus on
  /// (`regions.sample` already encodes that choice).
  static func colorAndSharpnessMetrics(
    grid: PixelGrid,
    regions: RegionSet,
    config: Config
  ) -> ColorAndSharpness {
    let meanR = mean(grid.red, width: grid.width, region: regions.sample).mean
    let meanB = mean(grid.blue, width: grid.width, region: regions.sample).mean
    // colorTempSkew is bounded in [-1, 1] by construction: for non-negative
    // meanR/meanB, |meanR - meanB| <= meanR + meanB < meanR + meanB +
    // colorEpsilon. The epsilon is a division-by-zero guard for an
    // all-black region, not a tunable product threshold, so it is a fixed
    // numerical constant rather than a `Config` field.
    let colorTempSkew = (meanR - meanB) / (meanR + meanB + colorEpsilon)

    let rawSharpnessVariance = laplacianVariance(
      grid.luma,
      width: grid.width,
      height: grid.height,
      region: regions.sample
    )
    let sharpness = rawSharpnessVariance / Float(config.lighting.sharpnessNormalizationDivisor)

    return ColorAndSharpness(colorTempSkew: colorTempSkew, sharpness: sharpness)
  }

  // MARK: - Region geometry

  /// Converts a normalized, bottom-left-origin ROI (Vision raw space) into a
  /// pixel-space `Region` in a top-row-first `PixelGrid`, clamped to the
  /// grid's bounds.
  private static func pixelRegion(for roi: CGRect, width: Int, height: Int) -> Region {
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let clamped = roi.intersection(unit)
    guard !clamped.isNull, !clamped.isEmpty else {
      return Region(rowRange: 0..<0, colRange: 0..<0)
    }

    let colStart = Int((clamped.minX * CGFloat(width)).rounded(.down))
    let colEnd = Int((clamped.maxX * CGFloat(width)).rounded(.up))
    // Bottom-left-origin y -> top-row-first pixel row: normalized y = 0 is
    // the bottom of the image (the largest row index); y = 1 is the top
    // (row 0). The ROI's top edge (larger y) therefore maps to the smaller
    // row index.
    let rowStart = Int(((1 - clamped.maxY) * CGFloat(height)).rounded(.down))
    let rowEnd = Int(((1 - clamped.minY) * CGFloat(height)).rounded(.up))

    return Region(
      rowRange: clampedRange(rowStart, rowEnd, limit: height),
      colRange: clampedRange(colStart, colEnd, limit: width)
    )
  }

  private static func clampedRange(_ start: Int, _ end: Int, limit: Int) -> Range<Int> {
    let lo = max(0, min(start, limit))
    let hi = max(lo, min(end, limit))
    return lo..<hi
  }

  private static func intersect(_ first: Range<Int>, _ second: Range<Int>) -> Range<Int> {
    let lo = max(first.lowerBound, second.lowerBound)
    let hi = max(lo, min(first.upperBound, second.upperBound))
    return lo..<hi
  }

  // MARK: - Statistics

  /// Mean of `values` restricted to `region`. Returns `(0, 0)` for an empty
  /// region.
  private static func mean(
    _ values: [Float],
    width: Int,
    region: Region
  ) -> (mean: Float, total: Int) {
    guard !region.rowRange.isEmpty, !region.colRange.isEmpty else { return (0, 0) }
    var sum: Float = 0
    var total = 0
    for row in region.rowRange {
      let base = row * width
      for col in region.colRange {
        sum += values[base + col]
        total += 1
      }
    }
    return (sum / Float(total), total)
  }

  /// Mean of `values` over the whole `width` x `height` grid, excluding
  /// `region`. Returns `(0, 0)` if `region` covers the entire grid.
  private static func meanExcluding(
    _ values: [Float],
    width: Int,
    height: Int,
    region: Region
  ) -> (mean: Float, total: Int) {
    var sum: Float = 0
    var total = 0
    for row in 0..<height {
      let rowInRegion = region.rowRange.contains(row)
      let base = row * width
      for col in 0..<width where !(rowInRegion && region.colRange.contains(col)) {
        sum += values[base + col]
        total += 1
      }
    }
    return total > 0 ? (sum / Float(total), total) : (0, 0)
  }

  /// Population mean and variance of `values`, computed via Accelerate.
  private static func meanAndVariance(_ values: [Float]) -> (mean: Float, variance: Float) {
    guard !values.isEmpty else { return (0, 0) }
    let count = vDSP_Length(values.count)

    var mean: Float = 0
    vDSP_meanv(values, 1, &mean, count)

    var squares = [Float](repeating: 0, count: values.count)
    vDSP_vsq(values, 1, &squares, 1, count)
    var meanOfSquares: Float = 0
    vDSP_meanv(squares, 1, &meanOfSquares, count)

    // max(0, ...) guards against a tiny negative result from floating-point
    // cancellation when variance is ~0.
    let variance = max(0, meanOfSquares - mean * mean)
    return (mean, variance)
  }

  /// Fraction of `values` at/above (`isHighlight == true`) or at/below
  /// (`isHighlight == false`) `threshold`.
  private static func clippedFraction(
    _ values: [Float],
    threshold: Float,
    isHighlight: Bool
  ) -> Float {
    guard !values.isEmpty else { return 0 }
    var count = 0
    for value in values where isHighlight ? value >= threshold : value <= threshold {
      count += 1
    }
    return Float(count) / Float(values.count)
  }

  /// Variance of the 3x3 Laplacian (kernel `[[0,1,0],[1,-4,1],[0,1,0]]`) of
  /// `luma`, evaluated at interior pixels of `region` (pixels need all four
  /// neighbors, so the outermost ring of the whole grid, and of `region`,
  /// is excluded). Returns 0 if `region` has no interior pixels. This is the
  /// unnormalized "variance of Laplacian" blur metric; callers divide by
  /// `Config.Lighting.sharpnessNormalizationDivisor` to bring it into an
  /// approximately 0...1 range.
  private static func laplacianVariance(
    _ luma: [Float],
    width: Int,
    height: Int,
    region: Region
  ) -> Float {
    guard width >= 3, height >= 3 else { return 0 }
    let interiorRows = intersect(region.rowRange, 1..<(height - 1))
    let interiorCols = intersect(region.colRange, 1..<(width - 1))
    guard !interiorRows.isEmpty, !interiorCols.isEmpty else { return 0 }

    var responses: [Float] = []
    responses.reserveCapacity(interiorRows.count * interiorCols.count)
    for row in interiorRows {
      let base = row * width
      for col in interiorCols {
        let center = luma[base + col]
        let up = luma[base - width + col]
        let down = luma[base + width + col]
        let left = luma[base + col - 1]
        let right = luma[base + col + 1]
        responses.append(up + down + left + right - 4 * center)
      }
    }
    return meanAndVariance(responses).variance
  }
}
