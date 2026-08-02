import AboutFaceCore
import CryptoKit
import Foundation

/// On-disk schema for `trial --json <path>`: an append-mode log of trial
/// SESSIONS (one session = one `trial` invocation, i.e. one tuning profile
/// under test), each holding its own per-trial metrics and aggregate. This
/// is what makes "successive sessions accumulate into one comparable file"
/// (task brief) concrete — the `--config <path>` A/B workflow is: run
/// `trial` once per exported tuning profile, same `--json` path, different
/// `--label`, then compare `sessions` entries.
///
/// `Codable`, not `Sendable` — this type is only ever touched from the
/// `trial` command's single top-level task, never shared across
/// concurrency domains (see `TrialCommand.swift`).
struct TrialSessionLog: Codable {
  var sessions: [SessionRecord]

  static let empty = TrialSessionLog(sessions: [])

  struct SessionRecord: Codable {
    var label: String
    /// `"defaults"` or the `--config` path's filename — never a full
    /// absolute path, so the log stays portable/shareable (task brief:
    /// "config hash or filename").
    var configSource: String
    /// SHA-256 of the exported `Config` JSON (sorted keys, for a stable
    /// digest) — the actual A/B identity check when two sessions share a
    /// `configSource` filename but the file's contents changed between
    /// runs, or two differently-named files happen to encode the same
    /// tuning.
    var configHash: String
    var dateISO8601: String
    var settleSeconds: Double
    var timeoutSeconds: Double
    var displacementThreshold: Double
    var trials: [TrialRecord]
    /// `nil` only in the brief window between a session's JSON row being
    /// created and its first trial completing (see
    /// `Trial.persistNewSession`); every write after that carries the
    /// aggregate over whatever trials have completed so far, which is what
    /// makes the log meaningfully inspectable if the process is
    /// interrupted mid-session (task brief: "JSON log flushed per
    /// completed trial, not at end").
    var aggregate: AggregateRecord?
  }

  struct TrialRecord: Codable {
    var index: Int
    /// `"settled"` or `"timedOut"` — a plain string rather than an enum so
    /// the schema never breaks decoding older log entries if this grows a
    /// third case later (§11's "migration must not break" spirit, applied
    /// here to a log file instead of `Config`).
    var outcome: String
    var tEnterSeconds: Double?
    var tSettledSeconds: Double?
    var overshootsX: Int
    var overshootsY: Int
    var overshootsTotal: Int
    var pathIntegral: Double
    var meanAbsErrorDuringSettle: Double?

    init(index: Int, metrics: TrialOutcomeMetrics) {
      self.index = index
      self.outcome = metrics.timedOut ? "timedOut" : "settled"
      self.tEnterSeconds = metrics.tEnterSeconds
      self.tSettledSeconds = metrics.tSettledSeconds
      self.overshootsX = metrics.overshootsX
      self.overshootsY = metrics.overshootsY
      self.overshootsTotal = metrics.overshootsTotal
      self.pathIntegral = metrics.pathIntegral
      self.meanAbsErrorDuringSettle = metrics.meanAbsErrorDuringSettle
    }
  }

  struct AggregateRecord: Codable {
    var trialCount: Int
    var medianSettledSeconds: Double?
    var meanSettledSeconds: Double?
    var stddevSettledSeconds: Double?
    var totalOvershoots: Int
    var timeoutCount: Int

    init(_ aggregate: TrialAggregate) {
      self.trialCount = aggregate.trialCount
      self.medianSettledSeconds = aggregate.medianSettledSeconds
      self.meanSettledSeconds = aggregate.meanSettledSeconds
      self.stddevSettledSeconds = aggregate.stddevSettledSeconds
      self.totalOvershoots = aggregate.totalOvershoots
      self.timeoutCount = aggregate.timeoutCount
    }
  }
}

/// Load/save + config-hashing for `TrialSessionLog`. A separate `enum`
/// (rather than static members on the struct) purely to mirror
/// `ConfigStore`'s own load/save-as-a-namespace shape elsewhere in this
/// codebase.
enum TrialSessionStore {
  /// Best-effort load: a missing file is a fresh log (`.empty`), and so is
  /// an unparseable one — this is a research log, not user data under
  /// §11's "must not silently reset" contract, so there is no backup-and-
  /// preserve obligation the way `ConfigStore.load` has. A caller that
  /// cares whether the file existed can check `FileManager` itself first.
  static func load(from url: URL) -> TrialSessionLog {
    guard let data = try? Data(contentsOf: url) else { return .empty }
    guard let log = try? JSONDecoder().decode(TrialSessionLog.self, from: data) else {
      return .empty
    }
    return log
  }

  /// Pretty-printed, sorted-keys, atomic write — same formatting posture as
  /// `ConfigStore.export` so the file is diff-friendly and safe to write
  /// after every trial (task brief's Ctrl-C safety requirement) without
  /// ever leaving a half-written file on disk.
  static func write(_ log: TrialSessionLog, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(log)
    try data.write(to: url, options: .atomic)
  }

  /// SHA-256 over `Config`'s sorted-keys JSON encoding — deterministic
  /// across runs and across machines for byte-identical `Config` values,
  /// which is the property the A/B comparison workflow needs (two sessions
  /// with different `--config` filenames but identical contents should
  /// read as the same tuning). `CryptoKit` rather than hand-rolled hashing:
  /// it's a system framework (no new dependency, no network), and matches
  /// this being a local, offline hash — nothing about §2's "no network"
  /// constraint is implicated by using it.
  static func configHash(_ config: Config) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(config)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
