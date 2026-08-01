import Foundation

/// One entry of `Fixtures/corpus/manifest.json` (spec §14). Decode-only —
/// neither `record-corpus` nor `verify-corpus` writes this file back; see
/// `CorpusCatalog`'s doc comment for why a clip's on-disk filename is
/// derived from its array position instead of this struct's `file` field.
struct ManifestEntry: Decodable, Sendable {
  let file: String
  let description: String
  let expectedCondition: String
  let notes: String
}

enum CorpusManifestError: Error, CustomStringConvertible {
  case notFound(searchedFrom: String)
  case countMismatch(expected: Int, found: Int)
  case decodeFailed(String)

  var description: String {
    switch self {
    case .notFound(let from):
      return "Could not locate Fixtures/corpus/manifest.json by walking up from \(from). "
        + "Pass --corpus-dir explicitly if you are running outside the repository checkout."
    case .countMismatch(let expected, let found):
      return "Fixtures/corpus/manifest.json has \(found) entries; expected \(expected) to match "
        + "spec §14's 20-clip list (CorpusCatalog.clips)."
    case .decodeFailed(let message):
      return "Could not parse Fixtures/corpus/manifest.json: \(message)"
    }
  }
}

enum CorpusManifest {
  /// Resolves the corpus fixture directory (containing `manifest.json` and
  /// `clips/`): `override` if given, else by walking up from the current
  /// working directory looking for `Fixtures/corpus/manifest.json`. This is
  /// what lets both commands work via `swift run` from the repo root (or
  /// any subdirectory of it) without a hardcoded absolute path, matching
  /// how contributors normally invoke SwiftPM executables.
  static func resolveCorpusDir(override: String?) throws -> URL {
    if let override {
      return URL(fileURLWithPath: override, isDirectory: true)
    }

    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<12 {
      let candidate = dir.appendingPathComponent("Fixtures/corpus/manifest.json")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return dir.appendingPathComponent("Fixtures/corpus", isDirectory: true)
      }
      let parent = dir.deletingLastPathComponent()
      if parent == dir { break }
      dir = parent
    }
    throw CorpusManifestError.notFound(searchedFrom: FileManager.default.currentDirectoryPath)
  }

  /// Loads and validates `manifest.json` under `corpusDir`, checking its
  /// count matches `CorpusCatalog.clips` 1:1 by array position — the two
  /// are deliberately separate sources (see `CorpusCatalog`'s doc comment)
  /// so this check is what keeps them from silently drifting apart.
  static func load(from corpusDir: URL) throws -> [ManifestEntry] {
    let url = corpusDir.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    let entries: [ManifestEntry]
    do {
      entries = try JSONDecoder().decode([ManifestEntry].self, from: data)
    } catch {
      throw CorpusManifestError.decodeFailed("\(error)")
    }
    guard entries.count == CorpusCatalog.clips.count else {
      throw CorpusManifestError.countMismatch(
        expected: CorpusCatalog.clips.count, found: entries.count)
    }
    return entries
  }
}
