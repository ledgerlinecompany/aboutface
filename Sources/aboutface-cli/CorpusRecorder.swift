// swiftlint and swift-format disagree on whether "AVFoundation" or "AboutFaceCore" sorts
// first (case-sensitive vs. case-insensitive lexicographic ordering); this order
// satisfies `swift format lint`, which the CI gate also enforces. Same situation as
// `FileCaptureSource.swift`'s Accelerate/AVFoundation ordering.
// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore
import CoreMedia

// swiftlint:enable sorted_imports

/// Records `seconds` of frames from an already-`start()`ed
/// `CameraCaptureSource` to an H.264 `.mov` at `url`.
///
/// Uses the same `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`
/// pattern as `Tests/AboutFaceCoreTests/CaptureSourceTests.swift`'s
/// `SyntheticMovie` helper (the reference encoder CLAUDE.md points to),
/// except sourced from a live realtime feed rather than synthetic frames —
/// so `expectsMediaDataInRealTime` is `true` here, unlike `SyntheticMovie`'s
/// offline `false`, and the session start time is the camera's own first
/// sample timestamp rather than `.zero`.
enum CorpusRecorder {
  /// Bundled purely to keep `record(_:)`'s parameter count within
  /// SwiftLint's limit — same reasoning as `CaptureSourceTests.swift`'s
  /// `SyntheticMovie.Dimensions`.
  struct Dimensions: Sendable {
    let width: Int
    let height: Int
  }

  struct Summary: Sendable {
    let frameCount: Int
    let elapsedSeconds: Double
  }

  /// Bundles the three `AVAssetWriter` pieces `writeFrames` needs — again
  /// purely to keep that function's parameter count within SwiftLint's
  /// limit, not a reusable abstraction elsewhere.
  private struct WriterPipeline {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
  }

  enum RecorderError: Error, CustomStringConvertible {
    case writerFailed(String)

    var description: String {
      switch self {
      case .writerFailed(let message):
        return "Recording failed: \(message)"
      }
    }
  }

  /// One ~1 Hz status update: elapsed whole seconds, frames written so far,
  /// and a best-effort face count from a ~1/sec `VisionBackend` sanity
  /// check. `faces` is `nil` when that check itself failed — inference
  /// failure must not abort the recording, since the point of the check is
  /// a cheap "are you in frame" hint, not a hard dependency (task brief:
  /// "degrade gracefully if inference fails").
  static func record(
    source: CameraCaptureSource,
    dimensions: Dimensions,
    to url: URL,
    seconds: Int,
    onStatus: (_ elapsedSeconds: Int, _ frameCount: Int, _ faces: Int?) -> Void
  ) async throws -> Summary {
    // Best-effort cleanup of a leftover file from a previous crashed/killed
    // run at this exact path — `AVAssetWriter` will not overwrite an
    // existing file.
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let (input, adaptor) = Self.makeInputAndAdaptor(dimensions: dimensions)
    writer.add(input)

    guard writer.startWriting() else {
      throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }

    let pipeline = WriterPipeline(writer: writer, input: input, adaptor: adaptor)
    let loopResult = await Self.writeFrames(
      source: source, pipeline: pipeline, seconds: seconds, onStatus: onStatus)

    input.markAsFinished()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting { continuation.resume() }
    }

    guard writer.status == .completed else {
      let message =
        writer.error?.localizedDescription
        ?? "writer did not complete (status \(writer.status.rawValue))"
      try? FileManager.default.removeItem(at: url)
      throw RecorderError.writerFailed(message)
    }
    guard loopResult.sessionStarted else {
      throw RecorderError.writerFailed("camera produced no frames")
    }

    return Summary(frameCount: loopResult.frameCount, elapsedSeconds: loopResult.elapsedSeconds)
  }

  private struct LoopResult {
    let frameCount: Int
    let elapsedSeconds: Double
    let sessionStarted: Bool
  }

  /// The per-frame consume/encode/report loop, split out of `record(_:)`
  /// purely to keep that function within SwiftLint's body-length limit —
  /// still `record(_:)`'s own logic, not a separate public surface.
  private static func writeFrames(
    source: CameraCaptureSource,
    pipeline: WriterPipeline,
    seconds: Int,
    onStatus: (_ elapsedSeconds: Int, _ frameCount: Int, _ faces: Int?) -> Void
  ) async -> LoopResult {
    let writer = pipeline.writer
    let input = pipeline.input
    let adaptor = pipeline.adaptor
    let backend = VisionBackend()
    let clock = ContinuousClock()
    var start: ContinuousClock.Instant?
    var deadline: ContinuousClock.Instant?
    var frameCount = 0
    var lastReportedSecond = -1
    var sessionStarted = false

    for await frame in source.frames {
      if start == nil {
        let now = clock.now
        start = now
        deadline = now.advanced(by: .seconds(seconds))
        writer.startSession(atSourceTime: frame.timestamp)
        sessionStarted = true
      }
      guard let deadline, clock.now < deadline else { break }

      // Drop (don't block on) a frame if the writer isn't ready yet, same
      // spirit as the camera's own `.bufferingNewest(1)` drop policy: a
      // dropped frame only lowers the clip's effective fps slightly, never
      // corrupts anything, and a blocking wait here would stall real-time
      // capture for no benefit.
      if input.isReadyForMoreMediaData {
        if adaptor.append(frame.pixelBuffer, withPresentationTime: frame.timestamp) {
          frameCount += 1
        }
      }

      let elapsed = clock.now - (start ?? clock.now)
      let wholeSeconds = Int(elapsed.components.seconds)
      if wholeSeconds != lastReportedSecond {
        lastReportedSecond = wholeSeconds
        let faces = await Self.faceSanityCheck(backend: backend, frame: frame)
        onStatus(wholeSeconds, frameCount, faces)
      }
    }

    return LoopResult(
      frameCount: frameCount,
      elapsedSeconds: Self.seconds(clock.now - (start ?? clock.now)),
      sessionStarted: sessionStarted
    )
  }

  /// Runs the backend once as a cheap in-frame sanity check; `nil` on any
  /// failure rather than propagating, since a Vision hiccup must not abort
  /// an otherwise-fine recording (task brief: "degrade gracefully").
  private static func faceSanityCheck(backend: VisionBackend, frame: CapturedFrame) async -> Int? {
    do {
      let observation = try await backend.analyze(frame)
      return observation?.faceCount ?? 0
    } catch {
      return nil
    }
  }

  private static func makeInputAndAdaptor(
    dimensions: Dimensions
  ) -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: dimensions.width,
      AVVideoHeightKey: dimensions.height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = true

    let sourceAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: dimensions.width,
      kCVPixelBufferHeightKey as String: dimensions.height,
    ]
    // swiftlint:enable trailing_comma
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)
    return (input, adaptor)
  }

  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
