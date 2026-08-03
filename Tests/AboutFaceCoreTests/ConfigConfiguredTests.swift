import Foundation
import Testing

@testable import AboutFaceCore

/// `Config.isConfigured` (§16.4): the "app configured" predicate that gates
/// whether `CameraGatingStateMachine` may auto-activate Monitor mode on a
/// busy camera (§12.2). Pure, `AVFoundation`-free — see `Config
/// +Configured.swift`'s doc comment for the maintainer's decision this
/// codifies.
struct ConfigConfiguredTests {

  @Test("Fresh defaults: not configured")
  func freshDefaultsIsNotConfigured() {
    #expect(Config.defaults.isConfigured == false)
  }

  @Test("An explicitly selected camera alone: configured")
  func selectedCameraAloneIsConfigured() {
    var config = Config.defaults
    config.camera.selectedCameraID = "FaceTime HD Camera (Built-in)"
    #expect(config.isConfigured == true)
  }

  @Test("A captured target alone: configured")
  func capturedTargetAloneIsConfigured() {
    var config = Config.defaults
    config.targetFraming.captured = true
    #expect(config.isConfigured == true)
  }

  @Test("Both a selected camera and a captured target: configured")
  func bothIsConfigured() {
    var config = Config.defaults
    config.camera.selectedCameraID = "FaceTime HD Camera (Built-in)"
    config.targetFraming.captured = true
    #expect(config.isConfigured == true)
  }

  @Test("targetFraming.captured defaults to false")
  func capturedDefaultsFalse() {
    #expect(Config.defaults.targetFraming.captured == false)
  }

  @Test("targetFraming.captured round-trips through Codable")
  func capturedRoundTrips() throws {
    var config = Config.defaults
    config.targetFraming.captured = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.targetFraming.captured == true)
  }

  /// An older config file with no `captured` key at all (every file written
  /// before this PR) must still decode leniently (§11) with `captured`
  /// falling back to its default of `false` — the exact scenario every
  /// pre-existing stored `config.json` is in the moment this PR ships.
  @Test("A config with no captured key decodes leniently, filling false")
  func missingCapturedKeyDecodesLeniently() throws {
    let defaultsData = try JSONEncoder().encode(Config.defaults)
    var defaultsObject = try #require(
      try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any])
    var targetFramingObject = try #require(defaultsObject["targetFraming"] as? [String: Any])
    targetFramingObject.removeValue(forKey: "captured")
    defaultsObject["targetFraming"] = targetFramingObject

    let data = try JSONSerialization.data(withJSONObject: defaultsObject)
    let decoded = try ConfigStore.decodeLeniently(data)

    #expect(decoded.targetFraming.captured == false)
  }
}
