import CoreGraphics
import CoreMedia
import CoreVideo
import Testing

@testable import AboutFaceCore

/// `AnalysisEngine.stream(from:targetAnalysisHz:)` (§5.2): proves the
/// decimation seam actually skips `backend.analyze(_:)` for dropped frames,
/// rather than analyzing every frame and discarding some `EngineOutput`s
/// afterward — `AnalysisRateDecimatorTests` covers the decimator's own
/// selection logic in isolation; this file covers that `AnalysisEngine`
/// wires it in at the right point.
struct AnalysisEngineDecimationTests {

  @Test("nil targetAnalysisHz (Setup's default) analyzes every frame, unchanged from before")
  func nilTargetAnalyzesEveryFrame() async throws {
    let backend = CountingBackend()
    let engine = AnalysisEngine(backend: backend, config: .defaults)
    let source = InMemoryCaptureSource(timestamps: thirtyHzTimestamps(count: 10))

    var outputCount = 0
    for try await _ in engine.stream(from: source) {
      outputCount += 1
    }

    #expect(outputCount == 10)
    #expect(await backend.callCount == 10)
  }

  @Test("§5.2's actual configuration: 15fps capture decimated to 5Hz analyzes only 5 of 15 frames")
  func fifteenFpsCaptureDecimatedToFiveHzAnalyzesOnlyOneThird() async throws {
    let backend = CountingBackend()
    let engine = AnalysisEngine(backend: backend, config: .defaults)
    let timestamps = (0..<15).map { CMTime(value: CMTimeValue($0), timescale: 15) }
    let source = InMemoryCaptureSource(timestamps: timestamps)

    var outputCount = 0
    for try await _ in engine.stream(from: source, targetAnalysisHz: 5) {
      outputCount += 1
    }

    // The critical assertion: the backend was called exactly as many times
    // as frames were actually analyzed — never once for a frame that was
    // then discarded. If decimation happened AFTER `process(_:)` instead of
    // before it, `callCount` here would be 15, not 5, even though
    // `outputCount` would still (misleadingly) read 5.
    #expect(outputCount == 5)
    #expect(await backend.callCount == 5)
  }

  private func thirtyHzTimestamps(count: Int) -> [CMTime] {
    (0..<count).map { CMTime(value: CMTimeValue($0), timescale: 30) }
  }
}

// MARK: - Test doubles

/// A `FaceAnalysisBackend` that counts how many times `analyze(_:)` was
/// actually invoked — distinct from `AnalysisEngineTestSupport.swift`'s
/// `ScriptedBackend`, which scripts return values but has no public call
/// count. Always reports "no face," since these tests only care about
/// invocation counts, not geometry.
actor CountingBackend: FaceAnalysisBackend {
  static let identifier = "counting-mock"
  static let displayName = "Counting Mock"
  static let isAvailable = true

  let capabilities: BackendCapabilities = [.headPose]

  private(set) var callCount = 0

  func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation? {
    callCount += 1
    return nil
  }
}

/// A `CaptureSource` that yields one frame per given timestamp, all sharing a
/// single 1x1 pixel buffer, then finishes — the minimal double needed to
/// drive `AnalysisEngine.stream(from:)` with fully controlled timestamps and
/// no real camera or file I/O.
struct InMemoryCaptureSource: CaptureSource {
  let mirrorState: MirrorState = .notMirrored
  let frames: AsyncStream<CapturedFrame>

  init(timestamps: [CMTime]) {
    let pixelBuffer = InMemoryCaptureSource.makeOnePixelBuffer()
    frames = AsyncStream { continuation in
      for timestamp in timestamps {
        continuation.yield(
          CapturedFrame(pixelBuffer: pixelBuffer, timestamp: timestamp, mirrorState: .notMirrored))
      }
      continuation.finish()
    }
  }

  func start() async throws {}
  func stop() async {}

  private static func makeOnePixelBuffer() -> CVPixelBuffer {
    var pixelBufferOrNil: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBufferOrNil)
    precondition(status == kCVReturnSuccess, "Failed to create test CVPixelBuffer")
    return pixelBufferOrNil!
  }
}
