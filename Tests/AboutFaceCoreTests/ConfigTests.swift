import Foundation
import Testing

@testable import AboutFaceCore

struct ConfigTests {

  @Test("Codable round-trip preserves every field")
  func roundTrip() throws {
    let original = Config(
      version: 3,
      targetFraming: Config.TargetFraming(
        eyeMidpointY: 0.41,
        eyeMidpointX: 0.52,
        interocularWidth: 0.13
      ),
      deadZone: Config.DeadZone(horizontal: 0.07, vertical: 0.045),
      hysteresisExitRatio: 1.6,
      dwellMs: 900,
      smoothingWindow: 10,
      lighting: Config.Lighting(
        clippedHighlightThreshold: 0.97,
        clippedShadowThreshold: 0.03,
        maxAnalysisWidth: 256,
        sharpnessNormalizationDivisor: 0.015
      )
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.self, from: data)

    #expect(decoded == original)
  }

  @Test("Defaults round-trip through Codable")
  func defaultsRoundTrip() throws {
    let data = try JSONEncoder().encode(Config.defaults)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded == Config.defaults)
  }

  // MARK: - §4 default values

  @Test("Default version is 1")
  func defaultVersion() {
    #expect(Config.defaults.version == 1)
  }

  @Test("Default target framing matches §4")
  func defaultTargetFraming() {
    #expect(Config.defaults.targetFraming.eyeMidpointY == 0.38)
    #expect(Config.defaults.targetFraming.eyeMidpointX == 0.50)
    #expect(Config.defaults.targetFraming.interocularWidth == 0.11)
  }

  @Test("Default dead zone matches §4")
  func defaultDeadZone() {
    #expect(Config.defaults.deadZone.horizontal == 0.06)
    #expect(Config.defaults.deadZone.vertical == 0.05)
  }

  @Test("Default hysteresis exit ratio matches §4")
  func defaultHysteresisExitRatio() {
    #expect(Config.defaults.hysteresisExitRatio == 1.4)
  }

  @Test("Default dwell time matches §7.1")
  func defaultDwellMs() {
    #expect(Config.defaults.dwellMs == 800)
  }

  @Test("Default smoothing window matches §4")
  func defaultSmoothingWindow() {
    #expect(Config.defaults.smoothingWindow == 8)
  }

  @Test("Default lighting thresholds match §3.3 starting points")
  func defaultLighting() {
    #expect(Config.defaults.lighting.clippedHighlightThreshold == 0.98)
    #expect(Config.defaults.lighting.clippedShadowThreshold == 0.02)
    #expect(Config.defaults.lighting.maxAnalysisWidth == 320)
    #expect(Config.defaults.lighting.sharpnessNormalizationDivisor == 0.02)
  }

  @Test("Lighting sub-struct round-trips through Codable independently")
  func lightingRoundTrip() throws {
    let original = Config.Lighting(
      clippedHighlightThreshold: 0.95,
      clippedShadowThreshold: 0.05,
      maxAnalysisWidth: 480,
      sharpnessNormalizationDivisor: 0.03
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.Lighting.self, from: data)
    #expect(decoded == original)
  }
}
