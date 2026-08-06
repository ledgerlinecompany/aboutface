import AboutFaceCore
import CryptoKit
import Foundation

/// On-disk schema for `acceptance --json <path>`, following
/// `TrialSessionLog`'s own precedent (`TrialSessionLog.swift`): an
/// append-mode log of SESSIONS, one per `acceptance` invocation, so
/// successive runs (different tuning profiles, different days) accumulate
/// into one comparable file instead of each run overwriting the last.
/// `Codable`, not `Sendable` — touched only from the `acceptance` command's
/// single top-level task, same as `TrialSessionLog`.
struct AcceptanceSessionLog: Codable {
  var sessions: [SessionRecord]

  static let empty = AcceptanceSessionLog(sessions: [])

  struct SessionRecord: Codable {
    var dateISO8601: String
    var configSource: String
    var configHash: String
    var requestedMinutes: Double
    var actualElapsedSeconds: Double
    /// `false` means the run stopped before `requestedMinutes` elapsed —
    /// see `terminationReason`. A reader MUST check this before treating
    /// the rest of the record as a complete acceptance run (PR brief: "a
    /// run that ends early or errors must say so loudly rather than
    /// printing a summary that looks complete" — this field is that
    /// loudness carried into the artifact, not just the terminal).
    var completedFullDuration: Bool
    /// `nil` only when `completedFullDuration` is `true`.
    var terminationReason: String?

    var capture: CaptureRecord
    var signal: SignalRecord
    var resources: ResourceRecord
    /// Idle windows before/after the session — §13's "impact" is a delta.
    var baselineBefore: ResourceWindowRecord
    var baselineAfter: ResourceWindowRecord
    var acceptance: AcceptanceRecord
  }

  struct CaptureRecord: Codable {
    var requestedWidth: Int
    var requestedHeight: Int
    var requestedFrameRateFps: Double
    var rawFrameCount: Int
    /// `nil` when fewer than two raw frames arrived to measure a span
    /// with — see `RawFrameArrivalCounter.snapshot()`.
    var achievedRawCaptureFps: Double?
    var requestedAnalysisHz: Double?
    var analyzedFrameCount: Int
    var achievedAnalysisFps: Double
    /// `"WxH"` strings, one per DISTINCT dimension observed, in order
    /// first seen — more than one entry means the delivered format
    /// changed mid-stream (§12.5).
    var observedDimensions: [String]
  }

  struct SignalRecord: Codable {
    var stateCounts: [String: Int]
    var faceLostEpisodes: Int
    var longestFaceLostMs: Int
    var totalFaceLostMs: Int
  }

  struct ResourceRecord: Codable {
    var sampleCount: Int
    var averageCpuPercent: Double?
    var peakCpuPercent: Double?
    var thermalEvents: [ThermalEventRecord]
  }

  struct ThermalEventRecord: Codable {
    var elapsedMs: Int
    var state: String
  }

  struct AcceptanceRecord: Codable {
    var referenceEpisodeStartMs: Int?
    var referenceEpisodeStartIsInferred: Bool
    var rungs: [RungRecord]
    var unexplainedEvents: [EventRecord]
    /// §6.1's liveness heartbeats as a COUNT plus first/last, not one record
    /// each: a 30-minute run produces ~170, and the artifact is meant to stay
    /// diffable across sessions. See `AcceptanceReport.heartbeats`.
    var heartbeatCount: Int
    /// How many face-lost episodes reached §7.3's STOP. Exactly one is the
    /// expected shape; zero means the criterion was not met.
    var escalatedEpisodeCount: Int
    /// Brief face-lost episodes that never escalated — expected in any real
    /// session, reported so they are neither mistaken for the judged episode
    /// nor buried in `unexplainedEvents`.
    var nonEscalatingEpisodes: [EpisodeRecord]
    var routineGoodZoneEntryCount: Int
    var firstHeartbeatMs: Int?
    var lastHeartbeatMs: Int?
    var strayRendererActivityDuringStop: [EventRecord]
  }

  struct EpisodeRecord: Codable {
    var startMs: Int
    var endMs: Int?
    var durationMs: Int?

    init(_ episode: AcceptanceEpisode) {
      startMs = episode.startMs
      endMs = episode.endMs
      durationMs = episode.durationMs
    }
  }

  /// One idle CPU/thermal window — see `AcceptanceBaseline`.
  struct ResourceWindowRecord: Codable {
    var sampleCount: Int
    var averageCpuPercent: Double
    var peakCpuPercent: Double
    var thermalEvents: [ThermalEventRecord]

    init(_ window: AcceptanceResourceWindow) {
      sampleCount = window.sampleCount
      averageCpuPercent = window.averageCpuPercent
      peakCpuPercent = window.peakCpuPercent
      thermalEvents = window.thermalEvents.map {
        ThermalEventRecord(elapsedMs: $0.elapsedMs, state: "\($0.state)")
      }
    }
  }

  struct RungRecord: Codable {
    var rung: String
    var matched: Bool
    var observedElapsedMs: Int?
    var expectedElapsedMs: Int?
    var toleranceMs: Int?
    var note: String

    init(_ result: AcceptanceReport.RungResult) {
      rung = result.rung.rawValue
      matched = result.matched
      observedElapsedMs = result.observedElapsedMs
      expectedElapsedMs = result.expectedElapsedMs
      toleranceMs = result.toleranceMs
      note = result.note
    }
  }

  struct EventRecord: Codable {
    var elapsedMs: Int
    var description: String

    init(_ event: AcceptanceEvent) {
      elapsedMs = event.elapsedMs
      description = AcceptanceDescribe.kind(event.kind)
    }
  }
}

/// Load/save + config-hashing for `AcceptanceSessionLog` — mirrors
/// `TrialSessionStore`'s own shape (`TrialSessionLog.swift`) exactly, down
/// to the "missing or unparseable file is a fresh log" load semantics
/// (this is a research/diagnostic log, not user data under §11's "must not
/// silently reset" contract) and the sorted-keys pretty-printed atomic
/// write.
enum AcceptanceSessionStore {
  static func load(from url: URL) -> AcceptanceSessionLog {
    guard let data = try? Data(contentsOf: url) else { return .empty }
    guard let log = try? JSONDecoder().decode(AcceptanceSessionLog.self, from: data) else {
      return .empty
    }
    return log
  }

  static func write(_ log: AcceptanceSessionLog, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(log)
    try data.write(to: url, options: .atomic)
  }

  /// SHA-256 over `Config`'s sorted-keys JSON encoding — identical approach
  /// and identical purpose to `TrialSessionStore.configHash(_:)`.
  static func configHash(_ config: Config) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(config)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
