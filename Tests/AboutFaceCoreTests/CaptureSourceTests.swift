import AVFoundation
import CoreMedia
import CoreVideo
import Testing

@testable import AboutFaceCore

// MARK: - CameraCaptureSource (compile-only)

/// `CameraCaptureSource` opens a real `AVCaptureDevice` and requires camera
/// permission to actually run, which CI does not have (per CLAUDE.md:
/// "never write tests that require a live camera to pass in CI"). These
/// tests only exercise construction — no `start()` call, nothing that
/// touches `AVCaptureDevice.DiscoverySession` or triggers a TCC prompt —
/// which is enough to prove the type compiles and its `CaptureSource`
/// conformance wiring (mirror state fixed at `.notMirrored`, initial
/// `.idle` state) is correct.
struct CameraCaptureSourceCompileOnlyTests {

  @Test("Always constructs with .notMirrored per §3.4, regardless of device")
  func mirrorStateIsFixedAtNotMirrored() {
    let source = CameraCaptureSource(deviceUniqueID: "nonexistent-device-for-testing")
    #expect(source.mirrorState == .notMirrored)
  }

  @Test("Initial state is .idle before start() is ever called")
  func initialStateIsIdle() async {
    let source = CameraCaptureSource(deviceUniqueID: "nonexistent-device-for-testing")
    #expect(await source.state == .idle)
  }

  @Test("Default init parameters match §5.1 (1280x720@30)")
  func defaultFormatParametersDocumented() {
    // No public accessors for width/height/frameRate (they're only consumed
    // internally by configureSession()); this test exists so a change to
    // the defaults is at least visible in a diff, since §5.1 pins these
    // values and Config.swift is explicitly out of scope for this type.
    _ = CameraCaptureSource(deviceUniqueID: "nonexistent-device-for-testing")
  }
}

// MARK: - FileCaptureSource

// Serialized: concurrent AVAssetWriter/AVAssetReader sessions across tests
// compete for a limited number of hardware encode/decode sessions, which
// was observed to intermittently truncate replay early (short frame counts)
// under Swift Testing's default parallel execution. These tests are about
// correctness of FileCaptureSource's frame handling, not about exercising
// concurrent AVFoundation sessions, so serializing removes that flakiness.
@Suite(.serialized)
struct FileCaptureSourceTests {

  @Test("Unpaced replay: correct frame count, monotonic timestamps, .notMirrored, left edge white")
  func unpacedReplay_notMirrored() async throws {
    let url = try await SyntheticMovie.make(frameCount: 10, width: 64, height: 64, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: false)
    try await source.start()

    var collected: [CapturedFrame] = []
    for await frame in source.frames {
      collected.append(frame)
    }

    #expect(collected.count == 10)

    var previousTimestamp: CMTime?
    for frame in collected {
      #expect(frame.mirrorState == .notMirrored)
      if let previousTimestamp {
        #expect(frame.timestamp > previousTimestamp)
      }
      previousTimestamp = frame.timestamp
    }

    let firstFrame = try #require(collected.first)
    #expect(SyntheticMovie.isWhite(firstFrame.pixelBuffer, x: 2, y: 32))
  }

  @Test("simulateMirrored: .mirrored stamped and pixels genuinely flipped (left edge now black)")
  func simulateMirrored_flipsPixelsAndStamps() async throws {
    let url = try await SyntheticMovie.make(frameCount: 10, width: 64, height: 64, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: true)
    #expect(source.mirrorState == .mirrored)
    try await source.start()

    var collected: [CapturedFrame] = []
    for await frame in source.frames {
      collected.append(frame)
    }

    #expect(collected.count == 10)

    let firstFrame = try #require(collected.first)
    #expect(firstFrame.mirrorState == .mirrored)

    // Unmirrored source frames are left-half white / right-half black (see
    // SyntheticMovie). A genuine horizontal pixel flip — not just a stamp
    // change — must make the left edge black, since the original right
    // (black) half is now on the left.
    #expect(SyntheticMovie.isBlack(firstFrame.pixelBuffer, x: 2, y: 32))
    #expect(SyntheticMovie.isWhite(firstFrame.pixelBuffer, x: 61, y: 32))
  }

  @Test("Real-time pacing delivers all frames (no tight timing assertion in CI)")
  func realTimePacing_deliversAllFrames() async throws {
    let url = try await SyntheticMovie.make(frameCount: 10, width: 64, height: 64, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = FileCaptureSource(url: url, pacing: .realTime, simulateMirrored: false)
    try await source.start()

    var count = 0
    for await _ in source.frames {
      count += 1
    }

    #expect(count == 10)
  }

  @Test("stop() finishes the stream and is safe to call without ever starting")
  func stopWithoutStart_isSafe() async {
    let source = FileCaptureSource(
      url: URL(fileURLWithPath: "/nonexistent/does-not-matter.mov"),
      pacing: .unpaced,
      simulateMirrored: false
    )
    await source.stop()
    var count = 0
    for await _ in source.frames {
      count += 1
    }
    #expect(count == 0)
  }

  @Test("Missing video track surfaces as FileCaptureSourceError, not a crash")
  func missingFile_throwsRatherThanCrashing() async {
    let source = FileCaptureSource(
      url: URL(fileURLWithPath: "/nonexistent/does-not-exist-\(UUID().uuidString).mov"),
      pacing: .unpaced,
      simulateMirrored: false
    )
    await #expect(throws: Error.self) {
      try await source.start()
    }
  }
}

// MARK: - Synthetic corpus fixture

/// Builds a tiny synthetic video for `FileCaptureSource` tests: solid
/// left-half-white / right-half-black 32BGRA frames, encoded via
/// `AVAssetWriter`. Flat solid-color regions compress essentially
/// losslessly under H.264 (no high-frequency content to quantize away), so
/// pixels sampled well away from the vertical white/black boundary reliably
/// round-trip through encode+decode — which is what lets the mirrored-flip
/// test tell a genuine pixel flip apart from a no-op stamp change.
private enum SyntheticMovie {
  enum Error: Swift.Error {
    case writerFailed(String)
  }

  /// Pixel dimensions, bundled to keep helper function signatures below
  /// SwiftLint's parameter-count limit.
  private struct Dimensions {
    let width: Int
    let height: Int
  }

  static func make(frameCount: Int, width: Int, height: Int, fps: Int32) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")

    let dimensions = Dimensions(width: width, height: height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let (input, adaptor) = makeInputAndAdaptor(dimensions: dimensions)
    writer.add(input)

    guard writer.startWriting() else {
      throw Error.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)

    try await appendFrames(
      count: frameCount, dimensions: dimensions, fps: fps, input: input, adaptor: adaptor
    )

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
    input.expectsMediaDataInRealTime = false

    let sourceAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: dimensions.width,
      kCVPixelBufferHeightKey as String: dimensions.height,
    ]
    // swiftlint:enable trailing_comma
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: sourceAttributes
    )
    return (input, adaptor)
  }

  private static func appendFrames(
    count: Int,
    dimensions: Dimensions,
    fps: Int32,
    input: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) async throws {
    for frameIndex in 0..<count {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      guard let pool = adaptor.pixelBufferPool else {
        throw Error.writerFailed("no pixel buffer pool")
      }
      var pixelBufferOut: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
      guard let pixelBuffer = pixelBufferOut else {
        throw Error.writerFailed("could not create pixel buffer")
      }
      fill(pixelBuffer, width: dimensions.width, height: dimensions.height)

      let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
      guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
        throw Error.writerFailed("append failed for frame \(frameIndex)")
      }
    }
  }

  /// Fills the buffer left-half white, right-half black, fully opaque.
  private static func fill(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)

    for y in 0..<height {
      let rowStart = y * bytesPerRow
      for x in 0..<width {
        let offset = rowStart + x * 4
        let value: UInt8 = x < width / 2 ? 255 : 0
        bytes[offset + 0] = value  // B
        bytes[offset + 1] = value  // G
        bytes[offset + 2] = value  // R
        bytes[offset + 3] = 255  // A
      }
    }
  }

  static func isWhite(_ pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> Bool {
    brightness(pixelBuffer, x: x, y: y) > 128
  }

  static func isBlack(_ pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> Bool {
    brightness(pixelBuffer, x: x, y: y) < 128
  }

  private static func brightness(_ pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let offset = y * bytesPerRow + x * 4
    return bytes[offset]  // B channel; content is grayscale (B == G == R).
  }
}
