import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import AboutFaceCore

/// Exercises the spec §3.4 MUST-test — "a corpus clip where the subject is
/// unambiguously to their own left/right produces the correct sign under
/// both mirrored and unmirrored capture configuration" — through the real
/// pipeline pieces that exist today: `FileCaptureSource` → `VisionBackend`
/// (real `DetectFaceRectanglesRequest` inference, not a stub) →
/// `EgocentricTransform`. There is deliberately no `AnalysisEngine` here —
/// that type is concurrent work on `phase1/analysis-engine` — so this test
/// wires the boundary manually, exactly as `AnalysisEngine` will.
///
/// Input is a `SyntheticCorpus` clip (a NASA public-domain still composited
/// onto a flat background, see `SyntheticCorpus.swift` and
/// `Fixtures/corpus/stills/ATTRIBUTION.md`), not a purpose-recorded webcam
/// clip — see that type's doc comment for why detected-face position is
/// only approximately, not exactly, `ClipSpec.faceCenter`.
///
/// Serialized for the same reason `CaptureSourceTests.FileCaptureSourceTests`
/// is: concurrent `AVAssetWriter`/`AVAssetReader` sessions compete for a
/// limited number of hardware encode/decode sessions, which can
/// intermittently truncate replay. This suite additionally performs real
/// Vision inference per sampled frame, so serializing also avoids
/// oversubscribing that.
@Suite(.serialized)
struct SyntheticCorpusEndToEndTests {

  /// Peake frontal portrait, face placed clearly toward image-LEFT
  /// (`faceCenter.x = 0.30`) in the still's own raw, unmirrored placement —
  /// large enough (`faceHeightFraction = 0.5`) for Vision to detect
  /// reliably. Chosen empirically: swept several sizes/placements against
  /// real `DetectFaceRectanglesRequest` calls (both directly on the
  /// composited buffer and round-tripped through H.264 encode/decode) before
  /// landing here — see this file's final report for the numbers observed.
  /// 640x480 keeps encode+decode+inference cheap; 30 frames @ 30fps is one
  /// second of held pose, sampled every 5th frame below.
  private static let mainSpec = SyntheticCorpus.ClipSpec(
    faceImagePath: "Fixtures/corpus/stills/frontal-peake.jpg",
    faceCenter: CGPoint(x: 0.30, y: 0.45),
    faceHeightFraction: 0.5,
    frameCount: 30,
    size: CGSize(width: 640, height: 480)
  )

  /// Sampling every frame would triple this suite's Vision-inference cost
  /// for no additional signal — the clip is a held pose, not motion — so
  /// only every 5th frame (indices 0, 5, ..., 25; 6 samples) is analyzed,
  /// keeping added CI time modest.
  private static let sampleStride = 5

  @Test("§3.4: egocentric X agrees across mirror configs; direction and yaw sanity")
  func egocentricAgreementAcrossMirrorConfigurations() async throws {
    let url = try await SyntheticCorpus.makeClip(Self.mainSpec)
    defer { try? FileManager.default.removeItem(at: url) }

    let unmirroredFrames = try await Self.replay(url: url, simulateMirrored: false)
    let mirroredFrames = try await Self.replay(url: url, simulateMirrored: true)

    #expect(unmirroredFrames.count == Self.mainSpec.frameCount)
    #expect(mirroredFrames.count == Self.mainSpec.frameCount)

    let backend = VisionBackend()
    var sampledCount = 0

    for index in stride(from: 0, to: Self.mainSpec.frameCount, by: Self.sampleStride) {
      let unmirroredFrame = unmirroredFrames[index]
      let mirroredFrame = mirroredFrames[index]

      // (a) A face IS detected in both mirror configurations.
      let unRaw = try #require(
        try await backend.analyze(unmirroredFrame),
        "Vision failed to detect the composited face (unmirrored), frame \(index)"
      )
      let mirRaw = try #require(
        try await backend.analyze(mirroredFrame),
        "Vision failed to detect the composited face (mirrored), frame \(index)"
      )

      let unEgoRect = EgocentricTransform.egocentricRect(
        unRaw.boundingBox, mirror: unmirroredFrame.mirrorState
      )
      let mirEgoRect = EgocentricTransform.egocentricRect(
        mirRaw.boundingBox, mirror: mirroredFrame.mirrorState
      )

      // (b) The SAME physical placement must read as the SAME egocentric X
      // regardless of mirror configuration — this is the whole point of
      // EgocentricTransform (see its doc comment's "critical invariant").
      // Generous tolerance: this is real Vision inference on a real
      // (if synthetic) frame, round-tripped through H.264 for the mirrored
      // leg via a genuine pixel flip (FileCaptureSource.simulateMirrored),
      // not the same bytes re-labeled.
      #expect(
        abs(unEgoRect.midX - mirEgoRect.midX) < 0.05,
        """
        egocentric X should agree across mirror configs at frame \(index): \
        unmirrored=\(unEgoRect.midX), mirrored=\(mirEgoRect.midX)
        """
      )

      // (c) Direction check, reasoned from EgocentricTransform's own doc
      // comment: `mainSpec` places the still at `faceCenter.x = 0.30` —
      // image-LEFT — in the RAW, UNMIRRORED frame `FileCaptureSource`
      // delivers when `simulateMirrored == false` (pixels pass through
      // untouched). Per EgocentricTransform: "a front-facing camera faces
      // the subject... the subject's own right hand appears on the *left*
      // side of the frame, exactly as it would if someone stood facing you
      // and raised their right hand." So a face on the LEFT of an
      // unmirrored frame belongs to a subject turned toward their OWN
      // RIGHT, and egocentric X (increasing = further toward the subject's
      // own right) must be > 0.5 here — NOT < 0.5, which is exactly the
      // inversion §3.4 exists to catch: naively reading "face is on the
      // left of the image" as "subject is on their own left" is backwards
      // for an unmirrored front-facing camera. The mirrored leg must agree
      // (mirroring undoes the facing-flip, but `simulateMirrored` also
      // physically re-flips the pixels, so the net egocentric reading is
      // unchanged — see (b)).
      #expect(
        unEgoRect.midX > 0.5,
        "face at image-left in an unmirrored frame is on the subject's own right"
      )
      #expect(
        mirEgoRect.midX > 0.5,
        "mirrored config must agree with the unmirrored egocentric reading"
      )

      // (d) Yaw. Mapping Vision's raw yaw sign into FaceGeometry's
      // egocentric convention is AnalysisEngine's job (concurrent work on
      // phase1/analysis-engine), not this test's — and ATTRIBUTION.md's
      // mirror-negation finding (n=2, turned-head subjects) is least
      // reliable for a near-frontal subject like Peake, where yaw is small
      // and noisy. So this only asserts |yaw| sanity: a frontal official
      // portrait must not read as an extreme head turn, in either mirror
      // configuration. (Observed empirically while tuning this fixture:
      // roughly -9deg to -11deg unmirrored, +11deg to +12deg mirrored —
      // consistent with ATTRIBUTION.md's "mirroring negates yaw" finding,
      // but that consistency is documentation, not an assertion here.)
      if let unYaw = unRaw.yaw {
        #expect(abs(unYaw) < 45, "unmirrored yaw should be sane for a frontal portrait: \(unYaw)")
      }
      if let mirYaw = mirRaw.yaw {
        #expect(abs(mirYaw) < 45, "mirrored yaw should be sane for a frontal portrait: \(mirYaw)")
      }

      sampledCount += 1
    }

    #expect(sampledCount == 6)
  }

  @Test("Dim variant: LightingAnalyzer reports lower faceLuma than the bright reference")
  func dimVariantHasLowerFaceLuma() async throws {
    // Same placement as `mainSpec`, but a dim, low-background-luma variant —
    // §14 clip 4 ("dim room, overall underexposed") in miniature. A shorter
    // clip: this test only samples one frame from each of two clips, so
    // there is no need to pay for 30 frames of encode/decode here.
    let dimSpec = SyntheticCorpus.ClipSpec(
      faceImagePath: Self.mainSpec.faceImagePath,
      faceCenter: Self.mainSpec.faceCenter,
      faceHeightFraction: Self.mainSpec.faceHeightFraction,
      faceBrightness: 0.25,
      backgroundLuma: 0.1,
      frameCount: 10,
      size: Self.mainSpec.size
    )
    let brightSpec = SyntheticCorpus.ClipSpec(
      faceImagePath: Self.mainSpec.faceImagePath,
      faceCenter: Self.mainSpec.faceCenter,
      faceHeightFraction: Self.mainSpec.faceHeightFraction,
      frameCount: 10,
      size: Self.mainSpec.size
    )

    let brightURL = try await SyntheticCorpus.makeClip(brightSpec)
    defer { try? FileManager.default.removeItem(at: brightURL) }
    let dimURL = try await SyntheticCorpus.makeClip(dimSpec)
    defer { try? FileManager.default.removeItem(at: dimURL) }

    let brightFrames = try await Self.replay(url: brightURL, simulateMirrored: false)
    let dimFrames = try await Self.replay(url: dimURL, simulateMirrored: false)
    #expect(brightFrames.count == brightSpec.frameCount)
    #expect(dimFrames.count == dimSpec.frameCount)

    let backend = VisionBackend()
    let brightMetrics = try await Self.lightingMetrics(
      for: brightFrames[brightFrames.count / 2], backend: backend
    )
    // Vision may lose the face entirely, or detect it with lower confidence,
    // at faceBrightness=0.25 / backgroundLuma=0.1 — that is expected and
    // fine (`lightingMetrics` falls back to a whole-frame ROI when Vision
    // reports nothing); tuning detection *behavior* under dim conditions
    // against a face detector is real-corpus work (§14), not this
    // synthetic-fixture smoke test's job. Only the raw lighting numbers are
    // asserted on here.
    let dimMetrics = try await Self.lightingMetrics(
      for: dimFrames[dimFrames.count / 2], backend: backend
    )

    #expect(dimMetrics.faceLuma < brightMetrics.faceLuma)
    #expect(dimMetrics.backgroundLuma < brightMetrics.backgroundLuma)
  }

  // MARK: - Helpers

  private static func replay(url: URL, simulateMirrored: Bool) async throws -> [CapturedFrame] {
    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: simulateMirrored)
    try await source.start()
    var frames: [CapturedFrame] = []
    for await frame in source.frames {
      frames.append(frame)
    }
    return frames
  }

  /// Runs `VisionBackend` and feeds its (possibly nil) bounding box straight
  /// into `LightingAnalyzer` as the ROI, in Vision's own raw image space —
  /// deliberately NOT egocentric-transformed first, per
  /// `LightingAnalyzer`'s documented coordinate-space contract ("must be
  /// normalized and bottom-left origin, matching Vision's raw... space").
  private static func lightingMetrics(
    for frame: CapturedFrame,
    backend: VisionBackend
  ) async throws -> LightingMetrics {
    let observation = try await backend.analyze(frame)
    return try LightingAnalyzer.analyze(
      pixelBuffer: frame.pixelBuffer,
      faceROI: observation?.boundingBox,
      config: Config.defaults
    )
  }
}
