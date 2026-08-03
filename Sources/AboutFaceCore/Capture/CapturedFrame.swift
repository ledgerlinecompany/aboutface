import CoreMedia
import CoreVideo

/// A single frame handed from a `CaptureSource` (camera or file replay) to a
/// `FaceAnalysisBackend` for analysis.
///
/// The spec does not define this type's shape (§3.2 only names it as the
/// backend's input parameter); it is deliberately kept minimal here and is
/// expected to evolve during Phase 1 as real backend and capture-session needs
/// become concrete (see docs/spec.md §13, Phase 1).
///
/// ## Sendability
///
/// `CapturedFrame` crosses from the capture queue to the analysis actor (see
/// spec §3.1's four concurrency domains), so it must be `Sendable`.
/// `CVPixelBuffer` is a Core Foundation type without an unconditional,
/// compiler-verified `Sendable` conformance in every SDK this package might
/// build against, so `CapturedFrame` is declared `@unchecked Sendable`. This
/// is safe under the following ownership contract: the capture queue
/// (`AVCaptureVideoDataOutput`'s delegate callback) constructs a
/// `CapturedFrame` once per sample buffer and does not retain or mutate the
/// underlying `CVPixelBuffer` after handing it off. From that point on the
/// buffer is treated as logically immutable for the lifetime of the
/// `CapturedFrame` value — no domain writes into it. If a future change needs
/// to mutate a pixel buffer in place after capture, this contract must be
/// revisited.
public struct CapturedFrame: @unchecked Sendable {
  /// The captured image data, in the backend's native pixel format.
  public let pixelBuffer: CVPixelBuffer

  /// Presentation timestamp of the sample, as delivered by AVFoundation (or
  /// synthesized by a corpus file replay source).
  public let timestamp: CMTime

  /// Whether this frame's image is horizontally mirrored, per §3.4. Must be
  /// set explicitly at capture session configuration and carried on every
  /// frame — never inferred downstream.
  public let mirrorState: MirrorState

  public init(pixelBuffer: CVPixelBuffer, timestamp: CMTime, mirrorState: MirrorState) {
    self.pixelBuffer = pixelBuffer
    self.timestamp = timestamp
    self.mirrorState = mirrorState
  }

  /// The ACTUAL pixel dimensions of this frame's image buffer — read
  /// directly off `pixelBuffer`, not whatever width/height a capture
  /// session was configured to request. `CVPixelBufferGetWidth`/`GetHeight`
  /// are O(1) attribute reads (they do not touch pixel data), so this is
  /// cheap to compute on every frame.
  ///
  /// This exists because a REQUESTED capture format is not proof of a
  /// DELIVERED one (PR #53: `AVCaptureSession`/`AVCaptureDevice` were found
  /// to silently revert a requested format on macOS under some ordering of
  /// calls — see `CameraCaptureSource.configureSession`'s doc comment for
  /// the full story). Trusting the request instead of reading back what was
  /// actually decoded into `pixelBuffer` would reproduce that exact mistake
  /// one layer up. Callers that need to know "what did the camera actually
  /// deliver this session" (the Setup window's capture-format row,
  /// `aboutface-cli live`'s summary) read this off a real captured frame —
  /// see `EngineOutput.capturedPixelDimensions`, which is this value
  /// threaded through `AnalysisEngine.process(_:)`.
  public var pixelDimensions: PixelDimensions {
    PixelDimensions(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
  }
}

/// The width/height half of `CapturedFrame.pixelDimensions` — deliberately a
/// tiny, standalone, `Equatable` value type (not a bare tuple) so it can be
/// compared, stored, and threaded through `EngineOutput` and `PipelineModel`
/// state without any of those call sites re-declaring a `(width: Int,
/// height: Int)` shape of their own.
public struct PixelDimensions: Sendable, Equatable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}
