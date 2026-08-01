import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Composites a committed public-domain still (`Fixtures/corpus/stills/`,
/// see `ATTRIBUTION.md`) onto a flat-gray background and encodes the result
/// as a short H.264 clip, so the §14 corpus pipeline can be exercised
/// end-to-end in CI before real purpose-recorded webcam clips exist.
///
/// This is a **stand-in**, not a simulation of a real capture session: it
/// answers "does the pipeline wiring work, deterministically, on content
/// with a real face in it" rather than "does this look like a real webcam
/// frame." Real corpus tuning (lighting thresholds, dwell behavior, etc.)
/// still needs the purpose-recorded clips §14 describes.
///
/// ## Determinism
///
/// Every input to `makeClip(_:)` is spec-derived: no randomness, no
/// `Date`/`UUID`-based file naming, no wall-clock dependence. The same
/// `ClipSpec` always produces byte-identical composited frames (modulo H.264
/// encoder determinism, which is itself deterministic for a given encoder
/// version/input) and is written to the same spec-derived path, so repeated
/// runs — and repeated test invocations across processes — are reproducible
/// and diffable. Any pre-existing file at that path is removed before
/// writing, since `AVAssetWriter` refuses to write to a path that already
/// exists.
///
/// ## Coordinate space of `ClipSpec.faceCenter`
///
/// Normalized, **bottom-left origin** — the same convention
/// `VisionBackend`'s raw output and `LightingAnalyzer.faceROI` use (see
/// those files' doc comments). This is also, conveniently, `CGContext`'s own
/// default (un-flipped) user-space convention: a `CGContext` created
/// directly over a `CVPixelBuffer`'s memory with no additional flip
/// transform places high-Y drawing at low-memory-address rows, which is the
/// top of the image as raster consumers (video encoders, `Vision`) see it.
/// (Verified empirically while writing this file: filling the upper half of
/// such a context's default user space landed in the pixel buffer's first
/// memory rows.) So `makeClip` draws directly, with no manual flip.
///
/// ## Why the detected face won't sit exactly at `faceCenter`
///
/// `faceCenter`/`faceHeightFraction` position and size the **still image**,
/// not the face within it. NASA portrait stills (see `ATTRIBUTION.md`) frame
/// the face with headroom, shoulders, and off-center crops that vary photo
/// to photo — the face itself occupies some sub-region of the still,
/// offset from the still's own center by an amount this type does not know
/// or attempt to compensate for. Consequently, Vision's detected bounding
/// box center will be *close to but not exactly* `faceCenter`. Tests built
/// on `SyntheticCorpus` clips MUST assert on signs/directions (left-of-center
/// vs. right-of-center, brighter vs. dimmer) and generous tolerances, never
/// exact positions — see `SyntheticCorpusEndToEndTests` for the pattern.
enum SyntheticCorpus {

  /// Describes one synthetic clip: a still image composited onto a flat
  /// background, held for `frameCount` identical frames.
  struct ClipSpec: Sendable, Equatable {
    /// Repo-relative path to the source still, e.g.
    /// `"Fixtures/corpus/stills/frontal-peake.jpg"`. Resolved against the
    /// repo root located from this file's own `#filePath` (see
    /// `SyntheticCorpus.repoRoot`), so it works regardless of the test
    /// runner's current working directory.
    var faceImagePath: String

    /// Normalized, bottom-left-origin position of the **still image's**
    /// center within the output frame (see the type-level doc comment for
    /// why this is not the same as the detected face's center).
    var faceCenter: CGPoint

    /// The still image's height, as a fraction of the output frame's
    /// height. Width is derived to preserve the still's own aspect ratio.
    var faceHeightFraction: CGFloat

    /// Multiplicative brightness applied to the still's drawn region only
    /// (not the background). `1.0` = as-supplied; values `< 1` darken via a
    /// `.multiply` blend, simulating an underexposed subject.
    var faceBrightness: CGFloat = 1.0

    /// Flat gray level (`0...1`) filling every pixel not covered by the
    /// still. Raise for a backlit-ish (bright background, dim subject)
    /// case.
    var backgroundLuma: CGFloat = 0.5

    /// Number of identical frames to encode. The composited content does
    /// not vary frame to frame — this is a held pose, not motion — which is
    /// enough to exercise capture replay, backend inference, and the
    /// egocentric transform deterministically.
    var frameCount: Int

    /// Output frame size in pixels.
    var size: CGSize

    // No explicit init: the compiler-synthesized memberwise initializer
    // already carries `faceBrightness`/`backgroundLuma`'s default values
    // (this type is internal, not public), so a hand-written one here would
    // be redundant — `swift format lint`'s `UseSynthesizedInitializer` rule
    // catches exactly this.
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case stillNotFound(URL)
    case stillDecodeFailed(URL)
    case contextCreationFailed
    case noBaseAddress
    case writerFailed(String)
    case pixelBufferPoolMissing
    case appendFailed(frameIndex: Int)

    var description: String {
      switch self {
      case .stillNotFound(let url):
        return "SyntheticCorpus: no still image at \(url.path)"
      case .stillDecodeFailed(let url):
        return "SyntheticCorpus: could not decode still image at \(url.path)"
      case .contextCreationFailed:
        return "SyntheticCorpus: could not create a CGContext over the destination pixel buffer"
      case .noBaseAddress:
        return "SyntheticCorpus: pixel buffer has no base address"
      case .writerFailed(let message):
        return "SyntheticCorpus: AVAssetWriter failed: \(message)"
      case .pixelBufferPoolMissing:
        return "SyntheticCorpus: adaptor has no pixel buffer pool"
      case .appendFailed(let frameIndex):
        return "SyntheticCorpus: append failed for frame \(frameIndex)"
      }
    }
  }

  /// Repo root, located from this file's own `#filePath` rather than the
  /// process's current working directory (which `swift test` does not
  /// guarantee is the repo root). Mirrors `BackendTests`'
  /// `realFaceFixtureDirectory` pattern.
  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // SyntheticCorpus.swift -> AboutFaceCoreTests/
      .deletingLastPathComponent()  // AboutFaceCoreTests/ -> Tests/
      .deletingLastPathComponent()  // Tests/ -> repo root
  }

  /// Directory synthetic clips are written into. Not per-process-unique on
  /// purpose (see the type-level doc comment on determinism); each file
  /// name already encodes its full `ClipSpec`, so distinct specs cannot
  /// collide and identical specs intentionally reuse the same path.
  private static var outputDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AboutFaceSyntheticCorpus", isDirectory: true)
  }

  /// Builds (or rebuilds) the clip described by `spec` and returns its file
  /// URL. Reuses the `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`
  /// pattern `CaptureSourceTests.SyntheticMovie` established: a real H.264
  /// `.mov`, `kCVPixelFormatType_32BGRA` source pixel buffers, non-real-time
  /// input pacing.
  ///
  /// Async (unlike the sketch signature this was scoped from) so it can
  /// reuse `SyntheticMovie`'s `isReadyForMoreMediaData` wait loop verbatim
  /// rather than reimplementing a blocking variant; every call site in this
  /// test target is already in an async test.
  static func makeClip(_ spec: ClipSpec) async throws -> URL {
    let stillURL = repoRoot.appendingPathComponent(spec.faceImagePath)
    guard FileManager.default.fileExists(atPath: stillURL.path) else {
      throw Error.stillNotFound(stillURL)
    }
    guard let imageSource = CGImageSourceCreateWithURL(stillURL as CFURL, nil),
      let stillImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      throw Error.stillDecodeFailed(stillURL)
    }

    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true
    )
    let url = outputDirectory.appendingPathComponent(fileName(for: spec))
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let (input, adaptor) = makeInputAndAdaptor(spec: spec)
    writer.add(input)

    guard writer.startWriting() else {
      throw Error.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)

    try await appendFrames(spec: spec, stillImage: stillImage, input: input, adaptor: adaptor)

    input.markAsFinished()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }

    guard writer.status == .completed else {
      throw Error.writerFailed(writer.error?.localizedDescription ?? "writer did not complete")
    }
    return url
  }

  // MARK: - Deterministic naming

  /// Every field of `spec` is folded into the file name, so distinct specs
  /// never collide and the same spec always resolves to the same path — no
  /// `UUID`/`Date` anywhere in this type.
  private static func fileName(for spec: ClipSpec) -> String {
    let stillStem = (spec.faceImagePath as NSString).lastPathComponent
    let stem = (stillStem as NSString).deletingPathExtension
    return String(
      format: "%@-fx%.3f-fy%.3f-fh%.3f-fb%.3f-bg%.3f-n%d-%dx%d.mov",
      stem,
      spec.faceCenter.x,
      spec.faceCenter.y,
      spec.faceHeightFraction,
      spec.faceBrightness,
      spec.backgroundLuma,
      spec.frameCount,
      Int(spec.size.width),
      Int(spec.size.height)
    )
  }

  // MARK: - AVAssetWriter plumbing (pattern from CaptureSourceTests.SyntheticMovie)

  private static func makeInputAndAdaptor(
    spec: ClipSpec
  ) -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(spec.size.width),
      AVVideoHeightKey: Int(spec.size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false

    let sourceAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(spec.size.width),
      kCVPixelBufferHeightKey as String: Int(spec.size.height),
    ]
    // swiftlint:enable trailing_comma
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: sourceAttributes
    )
    return (input, adaptor)
  }

  private static func appendFrames(
    spec: ClipSpec,
    stillImage: CGImage,
    input: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) async throws {
    let fps: Int32 = 30
    for frameIndex in 0..<spec.frameCount {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      guard let pool = adaptor.pixelBufferPool else {
        throw Error.pixelBufferPoolMissing
      }
      var pixelBufferOut: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
      guard let pixelBuffer = pixelBufferOut else {
        throw Error.appendFailed(frameIndex: frameIndex)
      }
      try render(spec: spec, stillImage: stillImage, into: pixelBuffer)

      let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
      guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
        throw Error.appendFailed(frameIndex: frameIndex)
      }
    }
  }

  // MARK: - CoreGraphics compositing

  /// Renders one composited frame directly into `pixelBuffer`'s own memory:
  /// flat `backgroundLuma` gray everywhere, then the still image drawn at
  /// `faceCenter`/`faceHeightFraction`, then (if `faceBrightness < 1`) a
  /// `.multiply`-blended darkening restricted to the still's own drawn rect
  /// so the background luma is unaffected by the "dim face" case.
  private static func render(
    spec: ClipSpec,
    stillImage: CGImage,
    into pixelBuffer: CVPixelBuffer
  ) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw Error.noBaseAddress
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let alphaInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
    let bitmapInfo = alphaInfo | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let context = CGContext(
        data: base,
        width: Int(spec.size.width),
        height: Int(spec.size.height),
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    else {
      throw Error.contextCreationFailed
    }

    let frameRect = CGRect(origin: .zero, size: spec.size)
    context.setFillColor(
      CGColor(
        red: spec.backgroundLuma, green: spec.backgroundLuma, blue: spec.backgroundLuma, alpha: 1
      )
    )
    context.fill(frameRect)

    let drawRect = stillDrawRect(spec: spec, stillImage: stillImage)
    context.draw(stillImage, in: drawRect)

    if spec.faceBrightness < 1.0 {
      context.saveGState()
      context.clip(to: drawRect)
      context.setBlendMode(.multiply)
      context.setFillColor(
        CGColor(
          red: spec.faceBrightness, green: spec.faceBrightness, blue: spec.faceBrightness,
          alpha: 1
        )
      )
      context.fill(drawRect)
      context.restoreGState()
    }
  }

  /// The rect the still image is drawn into: centered at `faceCenter`
  /// (normalized, bottom-left origin — see the type-level doc comment),
  /// sized so the still's height is `faceHeightFraction` of the frame
  /// height, with the still's own aspect ratio preserved for width.
  private static func stillDrawRect(spec: ClipSpec, stillImage: CGImage) -> CGRect {
    let drawHeight = spec.size.height * spec.faceHeightFraction
    let aspect = CGFloat(stillImage.width) / CGFloat(stillImage.height)
    let drawWidth = drawHeight * aspect
    let centerX = spec.faceCenter.x * spec.size.width
    let centerY = spec.faceCenter.y * spec.size.height
    return CGRect(
      x: centerX - drawWidth / 2,
      y: centerY - drawHeight / 2,
      width: drawWidth,
      height: drawHeight
    )
  }
}
