import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import AboutFaceCore

private func allCapabilityFlags() -> [BackendCapabilities] {
  [.headPose, .gaze, .metricDistance, .captureQuality, .multiFace]
}

struct BackendCapabilitiesTests {

  @Test("Individual flags are distinct bits")
  func distinctBits() {
    let all = allCapabilityFlags()
    for (i, a) in all.enumerated() {
      for (j, b) in all.enumerated() where i != j {
        #expect(!a.contains(b))
      }
    }
  }

  @Test("Union combines flags and contains() reports membership")
  func unionAndContains() {
    let combo: BackendCapabilities = [.captureQuality, .multiFace, .headPose]

    #expect(combo.contains(.captureQuality))
    #expect(combo.contains(.multiFace))
    #expect(combo.contains(.headPose))
    #expect(!combo.contains(.gaze))
    #expect(!combo.contains(.metricDistance))
  }

  @Test("Empty set contains nothing")
  func emptySet() {
    let empty: BackendCapabilities = []
    #expect(!empty.contains(.headPose))
    #expect(!empty.contains(.gaze))
  }

  @Test("Subtracting a flag removes only that flag")
  func subtracting() {
    let combo: BackendCapabilities = [.captureQuality, .multiFace, .headPose]
    let reduced = combo.subtracting(.multiFace)

    #expect(reduced.contains(.captureQuality))
    #expect(reduced.contains(.headPose))
    #expect(!reduced.contains(.multiFace))
  }

  @Test("Insert and remove behave like a standard OptionSet")
  func insertAndRemove() {
    var caps: BackendCapabilities = []
    caps.insert(.gaze)
    #expect(caps.contains(.gaze))

    caps.remove(.gaze)
    #expect(!caps.contains(.gaze))
  }
}

/// Exercises `VisionBackend`'s real Vision-inference pipeline (§13 Phase 1).
/// Every test here runs the actual `DetectFaceRectanglesRequest` /
/// `DetectFaceLandmarksRequest` / `DetectFaceCaptureQualityRequest` calls
/// against synthetic, locally-generated pixel buffers — no network, no
/// camera, no bundled binary assets — so this suite is safe in CI per
/// `CLAUDE.md`'s testing conventions.
struct VisionBackendTests {

  @Test("Reports the expected static identity")
  func staticIdentity() {
    #expect(VisionBackend.identifier == "vision")
    #expect(VisionBackend.displayName == "Apple Vision")
    #expect(VisionBackend.isAvailable == true)
  }

  @Test("Declares headPose, captureQuality, and multiFace capabilities, and nothing else")
  func declaredCapabilities() {
    let backend = VisionBackend()
    #expect(backend.capabilities.contains(.captureQuality))
    #expect(backend.capabilities.contains(.multiFace))
    #expect(backend.capabilities.contains(.headPose))
    #expect(!backend.capabilities.contains(.gaze))
    #expect(!backend.capabilities.contains(.metricDistance))
  }

  @Test("A solid-gray frame has no face: analyze() returns nil without throwing")
  func solidGrayFrameHasNoFace() async throws {
    let backend = VisionBackend()
    let frame = try Self.makeFrame(width: 640, height: 480) { _, _ in
      BGRAPixel(blue: 128, green: 128, red: 128, alpha: 255)
    }

    let result = try await backend.analyze(frame)
    #expect(result == nil)
  }

  @Test("A gradient frame has no face: analyze() returns nil without throwing")
  func gradientFrameHasNoFace() async throws {
    let backend = VisionBackend()
    let frame = try Self.makeFrame(width: 640, height: 480) { x, y in
      BGRAPixel(blue: UInt8(x % 256), green: UInt8(y % 256), red: UInt8((x + y) % 256), alpha: 255)
    }

    let result = try await backend.analyze(frame)
    #expect(result == nil)
  }

  /// A tiny (2x2) buffer is a degenerate case Vision must also handle
  /// without throwing — regression coverage for the original Phase 1
  /// scaffolding test, now exercised against real inference.
  @Test("A degenerate 2x2 frame has no face: analyze() returns nil without throwing")
  func tinyFrameHasNoFace() async throws {
    let backend = VisionBackend()
    let frame = try Self.makeFrame(width: 2, height: 2) { _, _ in
      BGRAPixel(blue: 0, green: 0, red: 0, alpha: 255)
    }

    let result = try await backend.analyze(frame)
    #expect(result == nil)
  }

  /// Real-face detection, gated on an optional local fixture.
  ///
  /// This repository does not commit any photo of a real person (see
  /// `Fixtures/corpus/README.md`: identifiable media of real people is
  /// deliberately excluded from the public repo). To exercise the
  /// real-detection path locally, place any `.jpg`/`.jpeg`/`.png` containing
  /// a clearly visible face at:
  ///
  /// ```
  /// Fixtures/corpus/clips/test-face/<anything>.jpg
  /// ```
  ///
  /// (`Fixtures/corpus/clips/` is already `.gitignore`d.) When no such file
  /// exists — the default state of any fresh checkout, including CI — this
  /// test is skipped via `.enabled(if:)`, not failed, per
  /// `Fixtures/corpus/README.md`'s "skip gracefully" rule.
  @Test(
    "Detects a face in the optional real-photo fixture, when present",
    .enabled(if: VisionBackendTests.realFaceFixtureURL != nil)
  )
  func detectsRealFaceWhenFixturePresent() async throws {
    guard let fixtureURL = Self.realFaceFixtureURL else {
      return
    }

    guard let imageSource = CGImageSourceCreateWithURL(fixtureURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      Issue.record("Could not decode fixture image at \(fixtureURL.path)")
      return
    }

    let pixelBuffer = try Self.makePixelBuffer(from: cgImage)
    let frame = CapturedFrame(
      pixelBuffer: pixelBuffer,
      timestamp: CMTime(value: 0, timescale: 600),
      mirrorState: .notMirrored
    )

    let backend = VisionBackend()
    let result = try await backend.analyze(frame)

    #expect(result != nil)
    #expect((result?.faceCount ?? 0) >= 1)
    #expect((result?.confidence ?? 0) > 0)
    if let boundingBox = result?.boundingBox {
      #expect(boundingBox.width > 0)
      #expect(boundingBox.height > 0)
    }
  }

  // MARK: - Fixture discovery

  /// Directory tests should look in for an optional real-face fixture; see
  /// `detectsRealFaceWhenFixturePresent()`'s doc comment.
  private static var realFaceFixtureDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BackendTests.swift -> AboutFaceCoreTests/
      .deletingLastPathComponent()  // AboutFaceCoreTests/ -> Tests/
      .deletingLastPathComponent()  // Tests/ -> repo root
      .appendingPathComponent("Fixtures/corpus/clips/test-face", isDirectory: true)
  }

  /// First image file found in `realFaceFixtureDirectory`, or `nil` if the
  /// directory doesn't exist or contains none. Never throws — absence is an
  /// expected, common state, not an error.
  private static var realFaceFixtureURL: URL? {
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: realFaceFixtureDirectory,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    return contents.first { imageExtensions.contains($0.pathExtension.lowercased()) }
  }

  // MARK: - Synthetic pixel buffer construction

  /// A single BGRA byte quadruple — used instead of a 4-tuple return value
  /// so the pixel-generator closures below stay SwiftLint's `large_tuple`
  /// clean.
  private struct BGRAPixel {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8
  }

  /// `CVPixelBufferCreate` attributes shared by every pixel buffer this file
  /// builds: request CGImage/CGContext-compatible memory layout, since
  /// `makePixelBuffer(from:)` draws into the buffer through a `CGContext`.
  /// Built imperatively (not as a multi-line dictionary literal) to sidestep
  /// SwiftLint's `trailing_comma` (no trailing comma on a multiline literal)
  /// and swift-format's `multiElementCollectionTrailingCommas` (wants one)
  /// disagreeing with each other.
  private static var pixelBufferAttributes: CFDictionary {
    var attributes: [CFString: Any] = [:]
    attributes[kCVPixelBufferCGImageCompatibilityKey] = true
    attributes[kCVPixelBufferCGBitmapContextCompatibilityKey] = true
    return attributes as CFDictionary
  }

  private static func makeFrame(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> BGRAPixel
  ) throws -> CapturedFrame {
    let pixelBuffer = try makeSyntheticPixelBuffer(width: width, height: height, pixel: pixel)
    return CapturedFrame(
      pixelBuffer: pixelBuffer,
      timestamp: CMTime(value: 0, timescale: 600),
      mirrorState: .notMirrored
    )
  }

  /// Builds a `kCVPixelFormatType_32BGRA` pixel buffer of the given size,
  /// filled by calling `pixel(x, y)` for every coordinate.
  private static func makeSyntheticPixelBuffer(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> BGRAPixel
  ) throws -> CVPixelBuffer {
    var pixelBufferOrNil: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      Self.pixelBufferAttributes,
      &pixelBufferOrNil
    )
    guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOrNil else {
      throw TestFixtureError.pixelBufferCreationFailed(status: status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw TestFixtureError.pixelBufferHasNoBaseAddress
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        let value = pixel(x, y)
        row[x * 4 + 0] = value.blue
        row[x * 4 + 1] = value.green
        row[x * 4 + 2] = value.red
        row[x * 4 + 3] = value.alpha
      }
    }

    return pixelBuffer
  }

  /// Converts a decoded `CGImage` (e.g. from a JPEG/PNG fixture) into a
  /// `kCVPixelFormatType_32BGRA` pixel buffer, matching the byte layout
  /// `AVCaptureVideoDataOutput` delivers in the real capture path.
  private static func makePixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
    var pixelBufferOrNil: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      cgImage.width,
      cgImage.height,
      kCVPixelFormatType_32BGRA,
      Self.pixelBufferAttributes,
      &pixelBufferOrNil
    )
    guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOrNil else {
      throw TestFixtureError.pixelBufferCreationFailed(status: status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let alphaInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
    let bitmapInfo = alphaInfo | CGBitmapInfo.byteOrder32Little.rawValue
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: cgImage.width,
      height: cgImage.height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    )
    guard let context else {
      throw TestFixtureError.cgContextCreationFailed
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

    return pixelBuffer
  }

  private enum TestFixtureError: Error {
    case pixelBufferCreationFailed(status: CVReturn)
    case pixelBufferHasNoBaseAddress
    case cgContextCreationFailed
  }
}
