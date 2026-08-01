import CoreGraphics
import Foundation
import Testing

@testable import AboutFaceCore

/// Generates a handful of §14-analog `SyntheticCorpus` specs — the seed of a
/// future synthesized mini-corpus — and smoke-tests that each one encodes
/// with the right frame count and reads back correctly via
/// `FileCaptureSource`. This is deliberately shallow: it proves the
/// generation + replay pipeline works for every category shape, not that
/// downstream signals (detection, framing error, lighting state) behave
/// correctly for that category — that belongs to real §14 corpus tuning,
/// once purpose-recorded clips exist.
///
/// Serialized for the same reason `CaptureSourceTests.FileCaptureSourceTests`
/// is: concurrent `AVAssetWriter`/`AVAssetReader` sessions compete for a
/// limited number of hardware encode/decode sessions.
@Suite(.serialized)
struct SyntheticCorpusCategoryTests {

  /// One entry per §14-analog category this smoke test covers, in one
  /// place so the mapping from spec to spec §14 clip number is visible at a
  /// glance. Not exhaustive — §14 lists 20 clips: this is "a handful,"
  /// covering the geometrically/photometrically distinct cases that are
  /// cheap to approximate with a still-image composite (no motion,
  /// suppression, or multi-person cases here; those need real clips).
  private struct CategorySpec {
    /// The §14 clip number this spec approximates.
    let clipNumber: Int
    let label: String
    let spec: SyntheticCorpus.ClipSpec
  }

  /// Shared placement/size baseline every category spec starts from, so the
  /// list below reads as "what's different about this category" rather than
  /// repeating every field.
  private static let baseImagePath = "Fixtures/corpus/stills/frontal-peake.jpg"
  private static let baseSize = CGSize(width: 640, height: 480)
  private static let baseFrameCount = 8

  // swiftlint and swift-format disagree on trailing commas in multiline collection
  // literals (swift-format requires them, swiftlint's default forbids them); this
  // block satisfies `swift format lint`, which the CI gate also enforces.
  // swiftlint:disable trailing_comma
  private static let categorySpecs: [CategorySpec] = [
    // §14 clip 1: "Well-lit, centered, looking at camera (the reference)."
    CategorySpec(
      clipNumber: 1,
      label: "centered-reference",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.5, y: 0.5),
        faceHeightFraction: 0.5,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
    // §14 clip 7: "Off to the subject's left." Per EgocentricTransform, in
    // an UNMIRRORED raw frame the subject's own left maps to HIGH raw image
    // X (right side of the frame) — so this places the still on
    // image-RIGHT, not image-left.
    CategorySpec(
      clipNumber: 7,
      label: "off-subjects-left",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.72, y: 0.5),
        faceHeightFraction: 0.5,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
    // §14 clip 8: "Off to the subject's right." Raw image-LEFT, per the
    // same unmirrored convention (the mirror image of clip 7's reasoning).
    CategorySpec(
      clipNumber: 8,
      label: "off-subjects-right",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.28, y: 0.5),
        faceHeightFraction: 0.5,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
    // §14 clip 9: "Too high in frame (only forehead)." Approximated here by
    // moving the still's center toward the top of the frame (high raw Y,
    // bottom-left origin) rather than literally cropping to a forehead —
    // a still-image composite has no independent control over what part of
    // the source photo is "in frame."
    CategorySpec(
      clipNumber: 9,
      label: "too-high",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.5, y: 0.85),
        faceHeightFraction: 0.5,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
    // §14 clip 5: "Too close." Approximated by a larger faceHeightFraction
    // (the still fills more of the frame), rather than a true perspective
    // change.
    CategorySpec(
      clipNumber: 5,
      label: "too-close",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.5, y: 0.55),
        faceHeightFraction: 0.9,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
    // §14 clip 4: "Dim room, overall underexposed."
    CategorySpec(
      clipNumber: 4,
      label: "dim",
      spec: SyntheticCorpus.ClipSpec(
        faceImagePath: baseImagePath,
        faceCenter: CGPoint(x: 0.5, y: 0.5),
        faceHeightFraction: 0.5,
        faceBrightness: 0.25,
        backgroundLuma: 0.1,
        frameCount: baseFrameCount,
        size: baseSize
      )
    ),
  ]
  // swiftlint:enable trailing_comma

  @Test(
    "Every §14-analog category spec encodes with the right frame count and replays via FileCaptureSource",
    arguments: SyntheticCorpusCategoryTests.categorySpecs.map { ($0.clipNumber, $0.label, $0.spec) }
  )
  func categorySpecEncodesAndReplays(
    clipNumber: Int,
    label: String,
    spec: SyntheticCorpus.ClipSpec
  ) async throws {
    let url = try await SyntheticCorpus.makeClip(spec)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: false)
    try await source.start()

    var frames: [CapturedFrame] = []
    for await frame in source.frames {
      frames.append(frame)
    }

    #expect(
      frames.count == spec.frameCount,
      "§14 clip \(clipNumber) (\(label)): expected \(spec.frameCount) frames, got \(frames.count)"
    )
    for frame in frames {
      #expect(frame.mirrorState == .notMirrored)
    }
  }
}
