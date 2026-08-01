import Foundation

/// Persistence for `Config` (spec §11): versioned JSON on disk, plus
/// export/import for sharing tuning profiles (§9's "this matters more than
/// it sounds").
///
/// §11's two hard requirements shape everything here:
///
/// 1. **Migration MUST NOT silently reset a user's tuning.** Loading is
///    therefore *lenient*: the stored JSON is deep-merged over the encoded
///    defaults before decoding, so a file written by an older app version
///    (missing newly added keys) still decodes, with only the missing keys
///    taking default values and every tuned value preserved. A corrupt file
///    is backed up beside the original — never deleted or overwritten —
///    before defaults are returned.
/// 2. **Migration MUST preserve unknown keys where possible.** Saving
///    deep-merges the encoded config over whatever JSON is already in the
///    file, keeping keys this app version doesn't know about (e.g. written
///    by a newer version, or a future backend's tuning block) instead of
///    dropping them on the round-trip.
///
/// `export` deliberately does NOT carry unknown keys: it is a clean
/// snapshot of *this* version's config for sharing with other users, not a
/// byte-preserving copy of the on-disk file.
public enum ConfigStore: Sendable {

  public enum StoreError: Error, Equatable {
    /// The file exists but is not valid JSON / not decodable as `Config`
    /// even after lenient merging. Thrown by `importConfig` only — `load`
    /// handles this case by backing up and returning defaults.
    case undecodable
    /// The file's `version` is newer than this app understands. Importing
    /// it could silently drop meaning, so it is refused (§11's
    /// preserve-don't-reset contract cuts both ways).
    case newerVersion(found: Int, supported: Int)
  }

  /// What `load` found on disk, so the app can surface it (e.g. a one-time
  /// "settings were reset" notice) instead of the reset being silent.
  public enum LoadIssue: Equatable, Sendable {
    /// No file at the URL — first launch, or the user deleted it.
    /// Defaults returned; not an error.
    case missing
    /// The file was unreadable/undecodable. Its original bytes were moved
    /// to `backupURL` (never deleted — §11) and defaults returned.
    case corruptBackedUp(backupURL: URL)
  }

  public struct LoadResult: Sendable {
    public let config: Config
    public let issue: LoadIssue?
  }

  /// `~/Library/Application Support/About Face/config.json` (sandboxed:
  /// the container's Application Support). Creates the directory if needed.
  public static func defaultURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("About Face", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
  }

  // MARK: - Load

  public static func load(from url: URL) -> LoadResult {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return LoadResult(config: .defaults, issue: .missing)
    }
    guard
      let data = try? Data(contentsOf: url),
      let config = try? decodeLeniently(data)
    else {
      let backup = backUp(corruptFileAt: url)
      return LoadResult(config: .defaults, issue: .corruptBackedUp(backupURL: backup))
    }
    return LoadResult(config: config, issue: nil)
  }

  // MARK: - Save

  /// Atomic write. Preserves top-level and nested keys already present in
  /// the file that this `Config` version doesn't encode (§11). Output is
  /// pretty-printed with sorted keys so successive saves diff cleanly.
  public static func save(_ config: Config, to url: URL) throws {
    let encoded = try jsonObject(from: config)
    var merged = encoded
    // swift-format requires the brace on its own line after a multiline
    // condition; swiftlint's opening_brace rule disagrees. Format wins.
    // swiftlint:disable opening_brace
    if let existingData = try? Data(contentsOf: url),
      let existing = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any]
    {
      // swiftlint:enable opening_brace
      // Unknown keys in `existing` survive; every key `config` encodes wins.
      merged = deepMerge(overlay: encoded, onto: existing)
    }
    let data = try JSONSerialization.data(
      withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
  }

  // MARK: - Export / import

  /// Clean snapshot for sharing: exactly this version's fields, no unknown
  /// keys carried along.
  public static func export(_ config: Config, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (try encoder.encode(config)).write(to: url, options: .atomic)
  }

  /// Explicit user action, so failures throw rather than degrade:
  /// `.undecodable` for junk, `.newerVersion` when the file's schema
  /// version is ahead of this app (importing it could silently drop
  /// meaning). Older/equal versions decode leniently like `load`.
  public static func importConfig(from url: URL) throws -> Config {
    guard
      let data = try? Data(contentsOf: url),
      let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      throw StoreError.undecodable
    }
    let supported = Config.defaults.version
    if let version = raw["version"] as? Int, version > supported {
      throw StoreError.newerVersion(found: version, supported: supported)
    }
    guard let config = try? decodeLeniently(data) else {
      throw StoreError.undecodable
    }
    return config
  }

  // MARK: - Internals

  /// Lenient decode (§11): deep-merge the stored JSON over the encoded
  /// defaults, then decode the merged object. Missing keys (older file,
  /// newer app) fall back to defaults per-key; present keys always win;
  /// unknown keys are ignored by the decoder (and preserved by `save`).
  static func decodeLeniently(_ data: Data) throws -> Config {
    guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw StoreError.undecodable
    }
    let defaults = try jsonObject(from: Config.defaults)
    let merged = deepMerge(overlay: stored, onto: defaults)
    let mergedData = try JSONSerialization.data(withJSONObject: merged)
    return try JSONDecoder().decode(Config.self, from: mergedData)
  }

  /// Recursive dictionary merge: `overlay` wins wherever both sides have a
  /// key; nested dictionaries merge key-by-key; everything else (including
  /// arrays) is replaced wholesale, not element-merged.
  static func deepMerge(overlay: [String: Any], onto base: [String: Any]) -> [String: Any] {
    var result = base
    for (key, value) in overlay {
      // Same swift-format/swiftlint multiline-condition brace conflict as in
      // save(_:to:) above; format wins.
      // swiftlint:disable opening_brace
      if let overlayDict = value as? [String: Any],
        let baseDict = result[key] as? [String: Any]
      {
        // swiftlint:enable opening_brace
        result[key] = deepMerge(overlay: overlayDict, onto: baseDict)
      } else {
        result[key] = value
      }
    }
    return result
  }

  private static func jsonObject(from config: Config) throws -> [String: Any] {
    let data = try JSONEncoder().encode(config)
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw StoreError.undecodable
    }
    return object
  }

  /// Moves a corrupt file to `<name>.invalid` beside the original (adding
  /// `-2`, `-3`, … if needed — deterministic, no timestamps), so the
  /// user's bytes are never destroyed (§11).
  private static func backUp(corruptFileAt url: URL) -> URL {
    let manager = FileManager.default
    var candidate = url.appendingPathExtension("invalid")
    var counter = 2
    while manager.fileExists(atPath: candidate.path) {
      candidate = url.appendingPathExtension("invalid-\(counter)")
      counter += 1
    }
    // A failed move leaves the corrupt file in place; the returned URL
    // still names where the backup was attempted. Callers treat the
    // backup as best-effort — the essential guarantee is that we never
    // delete or overwrite the user's file.
    try? manager.moveItem(at: url, to: candidate)
    return candidate
  }
}
