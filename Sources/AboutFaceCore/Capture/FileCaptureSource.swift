// swiftlint and swift-format disagree on whether "Accelerate" or "AVFoundation" sorts
// first (case-sensitive vs. case-insensitive lexicographic ordering); this order
// satisfies `swift format lint`, which the CI gate also enforces.
// swiftlint:disable sorted_imports
import AVFoundation
import Accelerate
import CoreMedia
import CoreVideo
// swiftlint:enable sorted_imports

/// A `CaptureSource` that replays a video file from disk instead of a live
/// camera — the corpus-replay half of spec §3.1's `(camera|file)`
/// abstraction, used by the §14 test corpus harness and by the mirror
/// convention acceptance test (§3.4).
///
/// ## Why `simulateMirrored` exists
///
/// Corpus clips (§14) are recorded once, unmirrored, straight off the
/// sensor. But the §3.4 acceptance test requires replaying the **same**
/// clip through the pipeline under both mirror configurations, to prove the
/// egocentric transform is correct regardless of how the live capture
/// session happens to be configured. A live `CameraCaptureSource` never
/// produces both variants of the same real-world moment — mirroring is a
/// property of the capture connection, fixed once per session — so a
/// recorded clip cannot be "replayed mirrored" by simply toggling a stamp:
/// the pixels themselves must change too, or the test would exercise the
/// egocentric transform's mirror-handling code path against image content
/// that was never actually mirrored, which proves nothing.
///
/// `AVCaptureConnection.isVideoMirrored = true` horizontally flips the pixel
/// data the session delivers (it is not just a metadata flag). So to
/// reproduce, byte-for-byte, what a live mirrored session would have
/// delivered for this same clip, `FileCaptureSource` performs the same
/// horizontal flip itself (via vImage) when `simulateMirrored` is `true`,
/// and stamps the result `.mirrored`. When `false`, frames pass through
/// untouched and are stamped `.notMirrored`. Either way, the stamp always
/// accurately describes the pixels actually delivered — the same invariant
/// `CapturedFrame.mirrorState` documents for every `CaptureSource`.
public actor FileCaptureSource: CaptureSource {
  /// How output frame delivery is paced relative to wall-clock time.
  public enum PacingMode: Sendable, Equatable {
    /// Frames are delivered at the rate their source timestamps imply —
    /// approximating a live capture session. Use for anything a human
    /// listens to or watches.
    case realTime

    /// Frames are delivered as fast as the consumer pulls them, with no
    /// artificial delay. Use for tests and offline corpus tuning, where
    /// wall-clock pacing only slows iteration without adding information.
    case unpaced
  }

  public nonisolated let mirrorState: MirrorState
  public nonisolated let frames: AsyncStream<CapturedFrame>

  private let continuation: AsyncStream<CapturedFrame>.Continuation
  private let url: URL
  private let pacing: PacingMode
  private let simulateMirrored: Bool

  private var reader: AVAssetReader?
  private var trackOutput: AVAssetReaderTrackOutput?
  private var readTask: Task<Void, Never>?

  public init(url: URL, pacing: PacingMode = .realTime, simulateMirrored: Bool = false) {
    self.url = url
    self.pacing = pacing
    self.simulateMirrored = simulateMirrored
    self.mirrorState = simulateMirrored ? .mirrored : .notMirrored

    // Unbounded, unlike the live camera source's `.bufferingNewest(1)`:
    // corpus replay exists to produce *deterministic* regression input
    // (§14 — "the only sane way to verify hysteresis does not chatter"),
    // and a dropping policy would make delivered-frame counts depend on
    // consumer scheduling. The buffer is bounded in practice by clip
    // length (a few hundred frames); see `CaptureSource`'s type-level
    // documentation for the live-vs-replay buffering distinction.
    let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(
      bufferingPolicy: .unbounded
    )
    self.frames = stream
    self.continuation = continuation
  }

  public func start() async throws {
    guard readTask == nil else { return }

    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw FileCaptureSourceError.noVideoTrack
    }

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw FileCaptureSourceError.readerFailed("cannot add track output")
    }
    reader.add(output)

    guard reader.startReading() else {
      let message = reader.error?.localizedDescription ?? "unknown reader error"
      throw FileCaptureSourceError.readerFailed(message)
    }
    self.reader = reader
    self.trackOutput = output

    readTask = Task { [weak self] in
      await self?.readLoop()
    }
  }

  public func stop() async {
    readTask?.cancel()
    await readTask?.value
    readTask = nil
    reader?.cancelReading()
    reader = nil
    trackOutput = nil
    continuation.finish()
  }

  private func readLoop() async {
    let clock = ContinuousClock()
    var previousTimestamp: CMTime?
    var previousEmitInstant: ContinuousClock.Instant?

    while !Task.isCancelled {
      guard let output = trackOutput, let sampleBuffer = output.copyNextSampleBuffer() else {
        break
      }
      guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
      let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if pacing == .realTime {
        if let previousTimestamp, let previousEmitInstant {
          let deltaSeconds = CMTimeGetSeconds(timestamp) - CMTimeGetSeconds(previousTimestamp)
          if deltaSeconds > 0 {
            let target = Duration.seconds(deltaSeconds)
            let elapsed = clock.now - previousEmitInstant
            if elapsed < target {
              try? await Task.sleep(for: target - elapsed)
            }
          }
        }
      }
      previousTimestamp = timestamp
      previousEmitInstant = clock.now

      let outputBuffer: CVPixelBuffer
      if simulateMirrored {
        guard let flipped = Self.horizontallyFlipped(imageBuffer) else {
          // A flip failure (allocation failure in practice) must NOT fall
          // back to yielding the unflipped buffer: the frame is stamped
          // `.mirrored`, and delivering pixels that don't match their
          // stamp is precisely the silent-inversion failure mode §3.4
          // exists to prevent — it would corrupt the mirror acceptance
          // test into passing against untransformed data. Ending the
          // stream early is loud (consumers observe a truncated replay);
          // wrong-stamped pixels are silent. Prefer loud.
          break
        }
        outputBuffer = flipped
      } else {
        outputBuffer = imageBuffer
      }

      let frame = CapturedFrame(
        pixelBuffer: outputBuffer,
        timestamp: timestamp,
        mirrorState: mirrorState
      )
      continuation.yield(frame)
    }

    continuation.finish()
  }

  /// Horizontally flips a 32BGRA pixel buffer's pixel data using vImage,
  /// reproducing what `AVCaptureConnection.isVideoMirrored` does to a live
  /// feed (see the type-level documentation for why this is necessary for
  /// the §3.4 acceptance test rather than just changing the mirror stamp).
  ///
  /// `vImageHorizontalReflect_ARGB8888` operates on 4-byte-per-pixel buffers
  /// purely by byte layout; it does not interpret channel semantics, so it
  /// is equally correct for BGRA as for ARGB — a pure horizontal reflect of
  /// 4-byte pixels is channel-order-agnostic.
  private nonisolated static func horizontallyFlipped(
    _ pixelBuffer: CVPixelBuffer
  ) -> CVPixelBuffer? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

    var srcBuffer = vImage_Buffer(
      data: srcBase,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: srcRowBytes
    )

    var outPixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &outPixelBuffer
    )
    guard status == kCVReturnSuccess, let outBuffer = outPixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(outBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }
    guard let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else { return nil }
    let dstRowBytes = CVPixelBufferGetBytesPerRow(outBuffer)

    var dstBuffer = vImage_Buffer(
      data: dstBase,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: dstRowBytes
    )

    let error = vImageHorizontalReflect_ARGB8888(
      &srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }

    return outBuffer
  }
}

public enum FileCaptureSourceError: Error, Sendable, Equatable {
  case noVideoTrack
  case readerFailed(String)
}
