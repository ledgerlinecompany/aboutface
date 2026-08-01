import Accelerate
import CoreGraphics
import CoreVideo

/// Computes `LightingMetrics` (spec §3.3) from a single captured frame.
///
/// ## Why this is a separate, stateless type
///
/// Per spec §6.2, "Lighting is NOT in the continuous loop... Lighting is
/// announced as a discrete state change only." `LightingAnalyzer` only
/// computes the raw numeric signals; deciding when those numbers cross a
/// threshold worth announcing, and debouncing/dwelling on that decision
/// (§7.1), is `AnalysisEngine`'s job, not this type's. `LightingAnalyzer`
/// is a pure function of pixel data plus `Config` — it holds no state,
/// makes no announcement decisions, and is safe to call from any
/// concurrency domain.
///
/// (The bulk of the pixel math — downsampling, luma/color decomposition,
/// region geometry, and the actual statistics — lives in
/// `LightingAnalyzerMath.swift`; this file holds the public entry point.)
///
/// ## Coordinate space of `faceROI`
///
/// `faceROI`, when supplied, must be normalized and **bottom-left origin**,
/// matching Vision's raw (pre-egocentric) coordinate space — the same space
/// `RawFaceObservation.boundingBox` is in before `EgocentricTransform` runs
/// (see that file's doc comment for the full mirroring discussion).
/// `LightingAnalyzer` works purely in image space and does not need
/// `MirrorState`: luma/color statistics over a region are identical
/// regardless of which direction is "the subject's right," so there is no
/// egocentric conversion to do here — that only matters once this ROI is
/// turned into directional feedback, which is out of scope for this type.
///
/// ## Performance
///
/// This can run at up to 30 Hz on 720p capture (§13 Phase 1 acceptance:
/// "runs a live camera at 30Hz without dropping frames"). To stay cheap,
/// the frame is downsampled — via `vImageScale_ARGB8888`, which resamples
/// each of the four 8-bit BGRA channels generically without needing to know
/// their semantics — to at most `config.lighting.maxAnalysisWidth` pixels
/// wide (aspect-preserving) before any per-pixel Swift-level work happens.
/// Luma/Laplacian/clipping work only ever touches that small downsampled
/// buffer, never the full-resolution source. Measured on this dev machine
/// (`LightingAnalyzerPerformanceTests` prints the actual figure; it is not
/// asserted on, since CI hardware varies), analyzing a synthetic 1280x720
/// BGRA frame downsampled to the default 320px-wide analysis buffer takes
/// roughly **~1 ms per call in a release (`-c release`) build** — comfortably
/// inside a 33 ms/frame budget at 30 Hz. An unoptimized debug build is far
/// slower (tens of ms per call, dominated by the un-vectorized per-pixel
/// Swift loop in `buildGrid`), so debug-build timings are not representative
/// of on-device real-time behavior; ship and profile this in release mode.
public enum LightingAnalyzer: Sendable {

  /// Thrown when the analyzer cannot process the given pixel buffer.
  public enum AnalyzerError: Error, Sendable, CustomStringConvertible {
    /// The buffer's pixel format is not `kCVPixelFormatType_32BGRA`, the
    /// project's standard capture format (see `CapturedFrame`).
    case unsupportedPixelFormat(OSType)
    /// `CVPixelBufferGetBaseAddress` returned `nil` for a locked buffer.
    case noBaseAddress
    /// The `vImage` downsample pass failed.
    case downsampleFailed(vImage_Error)

    public var description: String {
      switch self {
      case .unsupportedPixelFormat(let format):
        return "LightingAnalyzer requires kCVPixelFormatType_32BGRA, got pixel format \(format)"
      case .noBaseAddress:
        return "LightingAnalyzer could not read the pixel buffer's base address"
      case .downsampleFailed(let error):
        return "LightingAnalyzer's vImage downsample pass failed with error \(error)"
      }
    }
  }

  /// Computes every `LightingMetrics` field from a single frame.
  ///
  /// - Parameters:
  ///   - pixelBuffer: Must be `kCVPixelFormatType_32BGRA`; any other format
  ///     throws `AnalyzerError.unsupportedPixelFormat`.
  ///   - faceROI: Normalized, bottom-left origin (Vision raw space; see the
  ///     type-level doc comment). `nil` when no face is currently detected.
  ///   - config: Supplies the tunable thresholds and performance knobs in
  ///     `Config.Lighting`.
  public static func analyze(
    pixelBuffer: CVPixelBuffer,
    faceROI: CGRect?,
    config: Config
  ) throws -> LightingMetrics {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard pixelFormat == kCVPixelFormatType_32BGRA else {
      throw AnalyzerError.unsupportedPixelFormat(pixelFormat)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let grid = try downsampledGrid(
      pixelBuffer: pixelBuffer,
      maxWidth: config.lighting.maxAnalysisWidth
    )
    let regions = regionSet(grid: grid, faceROI: faceROI)
    let exposure = exposureMetrics(grid: grid, regions: regions, config: config)
    let colorAndSharpness = colorAndSharpnessMetrics(grid: grid, regions: regions, config: config)

    return LightingMetrics(
      faceLuma: exposure.faceLuma,
      backgroundLuma: exposure.backgroundLuma,
      backlightDelta: exposure.backgroundLuma - exposure.faceLuma,
      clippedHighlightFraction: exposure.clippedHighlightFraction,
      clippedShadowFraction: exposure.clippedShadowFraction,
      colorTempSkew: colorAndSharpness.colorTempSkew,
      sharpness: colorAndSharpness.sharpness,
      frameLumaVariance: exposure.frameLumaVariance
    )
  }
}
