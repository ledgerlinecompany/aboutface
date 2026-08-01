import Foundation
import Testing

@testable import AboutFaceCore

/// `ConfigStore` (spec §11): lenient loading that never silently resets a
/// user's tuning, unknown-key preservation on save, and strict-but-fair
/// import behavior.
struct ConfigStoreTests {

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("configstore-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  private func prepare(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  private func cleanUp(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("Save then load round-trips a tuned config")
  func saveLoadRoundTrip() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    var config = Config.defaults
    config.deadZone.horizontal = 0.123
    config.smoothingWindow = 3
    try ConfigStore.save(config, to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.issue == nil)
    #expect(result.config == config)
  }

  @Test("Missing file loads defaults and reports .missing")
  func missingFile() {
    let result = ConfigStore.load(from: temporaryURL())
    #expect(result.config == .defaults)
    #expect(result.issue == .missing)
  }

  @Test("Corrupt file is backed up (bytes preserved), defaults returned")
  func corruptFileBackedUp() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    let junk = Data("not json {{{".utf8)
    try junk.write(to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.config == .defaults)
    guard case .corruptBackedUp(let backupURL) = try #require(result.issue) else {
      Issue.record("expected .corruptBackedUp, got \(String(describing: result.issue))")
      return
    }
    // §11: the user's bytes are never destroyed.
    #expect(try Data(contentsOf: backupURL) == junk)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("Lenient decode: file missing newly added keys keeps tuned values, defaults the rest")
  func lenientDecodeOlderFile() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    var config = Config.defaults
    config.targetFraming.eyeMidpointX = 0.42
    try ConfigStore.save(config, to: url)

    // Simulate a file written before `lighting` existed.
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    stored.removeValue(forKey: "lighting")
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.issue == nil)
    #expect(result.config.targetFraming.eyeMidpointX == 0.42)  // tuned value preserved
    #expect(result.config.lighting == Config.defaults.lighting)  // missing block defaulted
  }

  @Test("Save preserves unknown top-level and nested keys (§11)")
  func savePreservesUnknownKeys() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    try ConfigStore.save(.defaults, to: url)
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    stored["futureKnob"] = 42
    var gaze = try #require(stored["gaze"] as? [String: Any])
    gaze["futureGazeKnob"] = "hold"
    stored["gaze"] = gaze
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    // Round-trip through load + save; the unknown keys must survive.
    let loaded = ConfigStore.load(from: url)
    #expect(loaded.issue == nil)
    try ConfigStore.save(loaded.config, to: url)

    let after = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(after["futureKnob"] as? Int == 42)
    #expect((after["gaze"] as? [String: Any])?["futureGazeKnob"] as? String == "hold")
    // And the known keys still decode to the same config.
    #expect(ConfigStore.load(from: url).config == loaded.config)
  }

  @Test("Import refuses a newer schema version")
  func importRefusesNewerVersion() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    try ConfigStore.save(.defaults, to: url)
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    stored["version"] = Config.defaults.version + 1
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    #expect(
      throws: ConfigStore.StoreError.newerVersion(
        found: Config.defaults.version + 1, supported: Config.defaults.version)
    ) {
      try ConfigStore.importConfig(from: url)
    }
  }

  @Test("Import throws .undecodable for junk; export produces a clean decodable snapshot")
  func importJunkAndExportSnapshot() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    try Data("[]".utf8).write(to: url)
    #expect(throws: ConfigStore.StoreError.undecodable) {
      try ConfigStore.importConfig(from: url)
    }

    var config = Config.defaults
    config.hysteresisExitRatio = 1.7
    try ConfigStore.export(config, to: url)
    let imported = try ConfigStore.importConfig(from: url)
    #expect(imported == config)
  }
}
