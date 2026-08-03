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

  @Test(
    "Lenient decode: absent brightnessStyle key fills in the default (.saw) via deep merge"
  )
  func lenientDecodeMissingBrightnessStyleDefaults() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    var config = Config.defaults
    config.audio.positional.maxBrightnessMix = 0.7  // a tuned value elsewhere in the same block
    try ConfigStore.save(config, to: url)

    // Simulate a file written before `brightnessStyle` existed (round-1
    // shape): strip only that key out of the nested `positional` object,
    // leaving its siblings (including the tuned `maxBrightnessMix`) intact
    // — exactly the "older file, newer app" shape §11's lenient load must
    // handle for an additive field nested inside an existing block, not
    // just at the top level (`lenientDecodeOlderFile` above already covers
    // a whole missing top-level block).
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var audio = try #require(stored["audio"] as? [String: Any])
    var positional = try #require(audio["positional"] as? [String: Any])
    positional.removeValue(forKey: "brightnessStyle")
    audio["positional"] = positional
    stored["audio"] = audio
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.issue == nil)
    #expect(result.config.audio.positional.maxBrightnessMix == 0.7)  // tuned value preserved
    #expect(result.config.audio.positional.brightnessStyle == .saw)  // missing key defaulted
  }

  @Test(
    "Lenient decode: absent baseline-learning gaze keys (§13 Phase 5) fill in defaults via deep merge"
  )
  func lenientDecodeMissingGazeBaselineKeysDefaults() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    var config = Config.defaults
    config.gaze.maxPitchDegrees = 12  // a tuned value elsewhere in the same block
    try ConfigStore.save(config, to: url)

    // Simulate a file written before `baselineLearningEnabled`/
    // `baselineAdaptationSeconds`/`baselineClampDegrees` existed: strip just
    // those three keys out of the nested `gaze` object, leaving the
    // pre-existing `maxYawDegrees`/`maxPitchDegrees` (including the tuned
    // value above) intact — same "older file, newer app, additive field
    // nested inside an existing block" shape as
    // `lenientDecodeMissingBrightnessStyleDefaults` above.
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var gaze = try #require(stored["gaze"] as? [String: Any])
    gaze.removeValue(forKey: "baselineLearningEnabled")
    gaze.removeValue(forKey: "baselineAdaptationSeconds")
    gaze.removeValue(forKey: "baselineClampDegrees")
    stored["gaze"] = gaze
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.issue == nil)
    #expect(result.config.gaze.maxPitchDegrees == 12)  // tuned value preserved
    #expect(result.config.gaze.baselineLearningEnabled == true)  // missing keys defaulted
    #expect(result.config.gaze.baselineAdaptationSeconds == 45)
    #expect(result.config.gaze.baselineClampDegrees == 25)
  }

  /// **Documented decision (2026-08-02, brightness-style round):** an
  /// UNKNOWN `brightnessStyle` raw string (not merely absent — present but
  /// invalid, e.g. from a future app version's since-removed style, or
  /// hand-edited/corrupted JSON) is a genuine decode failure:
  /// `Config.BrightnessStyle`'s synthesized `Decodable` conformance throws
  /// on an unrecognized raw value, which fails `decodeLeniently` entirely
  /// (not just that one field), and `ConfigStore.load` already treats any
  /// whole-file decode failure as corrupt — backed up, never silently
  /// dropped, defaults returned (§11's actual guarantee is "never destroy
  /// the user's bytes," not "always decode something"). This is judged
  /// acceptable rather than adding a custom lenient single-enum decoder:
  /// the failure mode this guards against (a hand-edited or truncated
  /// enum string) is rare, the fallback is safe and recoverable, and a
  /// custom decoder would add real complexity (hand-written `init(from:)`
  /// for `AudioPositional`, bypassing `Equatable`/`Codable` synthesis) for
  /// a case §11 already has a working answer for.
  @Test("Unknown brightnessStyle raw value fails the whole decode; treated as corrupt, backed up")
  func unknownBrightnessStyleTreatedAsCorrupt() throws {
    let url = temporaryURL()
    try prepare(url)
    defer { cleanUp(url) }

    try ConfigStore.save(.defaults, to: url)
    var stored = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var audio = try #require(stored["audio"] as? [String: Any])
    var positional = try #require(audio["positional"] as? [String: Any])
    positional["brightnessStyle"] = "wobble"  // not a valid Config.BrightnessStyle case
    audio["positional"] = positional
    stored["audio"] = audio
    try JSONSerialization.data(withJSONObject: stored).write(to: url)

    let result = ConfigStore.load(from: url)
    #expect(result.config == .defaults)
    guard case .corruptBackedUp(let backupURL) = try #require(result.issue) else {
      Issue.record("expected .corruptBackedUp, got \(String(describing: result.issue))")
      return
    }
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    #expect(!FileManager.default.fileExists(atPath: url.path))
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
