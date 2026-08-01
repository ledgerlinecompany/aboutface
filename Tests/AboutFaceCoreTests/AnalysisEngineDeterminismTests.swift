import CoreGraphics
import Testing

@testable import AboutFaceCore

struct AnalysisEngineDeterminismTests {

  private func makeScript() -> [RawFaceObservation?] {
    // swiftlint and swift-format disagree on trailing commas in multiline collection
    // literals (swift-format requires them, swiftlint's default forbids them); this
    // block satisfies `swift format lint`, which the CI gate also enforces.
    // swiftlint:disable trailing_comma
    [
      RawFaceObservation(
        boundingBox: CGRect(x: 0.3, y: 0.35, width: 0.2, height: 0.3),
        eyePoints: [CGPoint(x: 0.38, y: 0.5), CGPoint(x: 0.42, y: 0.5)],
        yaw: 8, pitch: -3, roll: 2,
        captureQuality: 0.7,
        confidence: 0.85,
        faceCount: 1
      ),
      nil,
      RawFaceObservation(
        boundingBox: CGRect(x: 0.45, y: 0.4, width: 0.22, height: 0.32),
        eyePoints: [CGPoint(x: 0.52, y: 0.55), CGPoint(x: 0.56, y: 0.55)],
        yaw: -4, pitch: 1, roll: -1,
        captureQuality: 0.9,
        confidence: 0.95,
        faceCount: 1
      ),
    ]
    // swiftlint:enable trailing_comma
  }

  private func run() async throws -> [(FrameAnalysis, FramingState?)] {
    let engine = AnalysisEngine(backend: ScriptedBackend(makeScript()))
    var results: [(FrameAnalysis, FramingState?)] = []
    for index in 0..<3 {
      let pixelBuffer = index == 1 ? uniformPixelBuffer() : gradientPixelBuffer()
      let output = try await engine.process(
        testFrame(pixelBuffer: pixelBuffer, mirror: .notMirrored, frameIndex: index))
      results.append((output.analysis, output.framing))
    }
    return results
  }

  /// Field-by-field comparison: neither `FrameAnalysis` nor `FramingState`
  /// is `Equatable` (they're spec-defined types this task may not modify),
  /// so determinism is checked scalar field by scalar field instead.
  private func expectEqual(
    _ lhs: (FrameAnalysis, FramingState?), _ rhs: (FrameAnalysis, FramingState?)
  ) {
    #expect(lhs.0.signalState == rhs.0.signalState)
    #expect(lhs.0.faceCount == rhs.0.faceCount)
    #expect(lhs.0.timestamp == rhs.0.timestamp)
    #expect(lhs.0.primary?.boundingBox == rhs.0.primary?.boundingBox)
    #expect(lhs.0.primary?.eyeMidpoint == rhs.0.primary?.eyeMidpoint)
    #expect(lhs.0.primary?.yaw == rhs.0.primary?.yaw)
    #expect(lhs.0.primary?.pitch == rhs.0.primary?.pitch)
    #expect(lhs.0.primary?.roll == rhs.0.primary?.roll)
    #expect(lhs.0.lighting.faceLuma == rhs.0.lighting.faceLuma)
    #expect(lhs.0.lighting.backgroundLuma == rhs.0.lighting.backgroundLuma)
    #expect(lhs.1?.error == rhs.1?.error)
    #expect(lhs.1?.distanceError == rhs.1?.distanceError)
    #expect(lhs.1?.inDeadZone == rhs.1?.inDeadZone)
    #expect(lhs.1?.gazeOnCamera == rhs.1?.gazeOnCamera)
  }

  @Test("Identical scripted frame sequence through two fresh engines produces identical output")
  func sameSequenceTwice_identicalOutput() async throws {
    let first = try await run()
    let second = try await run()

    #expect(first.count == second.count)
    for (lhs, rhs) in zip(first, second) {
      expectEqual(lhs, rhs)
    }
  }
}
