import AboutFaceCore
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `trial --snapshots <dir>` — three JPEGs per trial (go-signal, settled,
/// timeout) so a sighted reviewer can audit, by eye, whether this harness's
/// notion of SETTLED actually corresponds to good framing. The maintainer
/// who requested this is blind and cannot judge the pictures directly; they
/// exist solely to hand to a sighted second opinion, never fed back into the
/// trial's own spoken/printed feedback (that stays audio-only, per §1's
/// "appearance description is a non-goal" — these are raw frames for a human
/// reviewer, not a generated description).
///
/// Absent `--snapshots`, none of this activates: `Trial.runSession`
/// (`TrialProtocol.swift`) only constructs a `TrialSnapshotWriter` when the
/// option is given, and only then does the frame pump retain the live
/// `CapturedFrame` needed to write one (see `TrialHub.publish(_:frame:)` in
/// `TrialRuntime.swift`) — zero behavioral change and zero retained frames
/// otherwise.
enum TrialSnapshotMoment: String {
  case start
  case settled
  case timeout
}

/// Stateless JPEG writer for one trial session's snapshots — every `write`
/// call is independent (no mutable counters), so this stays a plain
/// `Sendable` value that `TrialContext` can hold directly alongside its
/// other read-only fields. The destination directory is created lazily, on
/// first successful capture, rather than eagerly at session start, so a
/// session that never gets past the no-camera error path (`Trial.run()`
/// checks for a camera before `runSession` ever constructs this type) never
/// touches disk.
struct TrialSnapshotWriter: Sendable {
  let directory: URL
  let label: String

  /// `nil` exactly when `directoryPath` is `nil` (i.e. `--snapshots` was not
  /// given) — the one place the whole feature is gated off.
  init?(directoryPath: String?, label: String) {
    guard let directoryPath else { return nil }
    self.directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    self.label = label
  }

  /// `<label>-trial<N>-<moment>.jpg`. Any `/` in a free-text `--label` is
  /// flattened to `-` so the label can never escape `directory` into an
  /// unintended subpath; pure string formatting, so it's covered directly by
  /// `TrialSelfTest` without needing a `CVPixelBuffer` or disk I/O.
  static func filename(label: String, trial index: Int, moment: TrialSnapshotMoment) -> String {
    let safeLabel = label.replacingOccurrences(of: "/", with: "-")
    return "\(safeLabel)-trial\(index)-\(moment.rawValue).jpg"
  }

  /// Writes `frame`'s pixel buffer as a JPEG and returns the written
  /// filename (relative to `directory`, for the session JSON log) — `nil` if
  /// `frame` is unavailable (nothing retained yet, e.g. no frame has arrived
  /// at all) or the write failed. Per the task brief, a snapshot failure
  /// must never fail the trial: this prints one warning and returns `nil`
  /// rather than throwing, and callers never treat a `nil` here as fatal.
  /// Existing files at the destination are overwritten silently (the same
  /// label + trial number re-run is an intentional re-take).
  func write(_ frame: CapturedFrame?, trial index: Int, moment: TrialSnapshotMoment) -> String? {
    guard let frame else { return nil }
    let filename = Self.filename(label: label, trial: index, moment: moment)
    let url = directory.appendingPathComponent(filename)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Self.writeJPEG(pixelBuffer: frame.pixelBuffer, to: url)
      return filename
    } catch {
      print("Warning: could not write snapshot \(filename): \(error)")
      return nil
    }
  }

  private enum WriteError: Error {
    case renderFailed
    case destinationFailed
    case finalizeFailed
  }

  // Duplicated (not extracted to a shared helper) from
  // VerifyCorpusCommand.swift's `writeJPEG(pixelBuffer:to:)` — its --stills
  // export uses this exact CIImage -> CGImage -> CGImageDestination
  // technique. This task's scope is Trial*.swift plus this one new file;
  // VerifyCorpusCommand.swift is out of bounds even for a behavior-
  // preserving refactor, so the ~15 lines are copied here rather than
  // shared.
  private static func writeJPEG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      throw WriteError.renderFailed
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw WriteError.destinationFailed
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw WriteError.finalizeFailed
    }
  }
}

/// The snapshot filenames written for one trial — `start` is attempted once
/// the go signal fires (the displaced starting pose), and exactly one of
/// `settled`/`timeout` is attempted, matching the trial's outcome. Threaded
/// from `Trial.runOneTrial` (`TrialProtocol.swift`) into the
/// `TrialSessionLog.TrialRecord` it appends. All three stay `nil` for a
/// session run without `--snapshots`.
struct TrialSnapshotPaths: Equatable {
  var start: String?
  var settled: String?
  var timeout: String?

  static let none = TrialSnapshotPaths()
}

// MARK: - Self-test coverage (trial --self-test-metrics)

/// `--snapshots`-specific checks for `TrialSelfTest` — kept in this file
/// (rather than `TrialSelfTestChecks.swift`, where every other check lives)
/// purely to stay under SwiftLint's `file_length` limit there; thematically
/// this is exactly where the rest of `TrialSnapshots.swift`'s reader would
/// look for it. See `TrialSelfTest.swift` for the overall coverage
/// statement and dispatch list (`checkSnapshotFields` is called from
/// `TrialSelfTest.run()`).
extension TrialSelfTest {
  static func checkSnapshotFields(_ failures: inout [Failure]) {
    checkSnapshotFilename(&failures)
    checkSnapshotFieldsRoundTrip(&failures)
    checkSnapshotFieldsBackwardCompatible(&failures)
  }

  /// `TrialSnapshotWriter.filename` is pure string formatting — no
  /// `CVPixelBuffer` or disk I/O needed to check it produces exactly
  /// `<label>-trial<N>-<moment>.jpg` and flattens a `/` in a free-text
  /// `--label` so the label can never escape the snapshots directory.
  private static func checkSnapshotFilename(_ failures: inout [Failure]) {
    expect(
      TrialSnapshotWriter.filename(label: "defaults", trial: 3, moment: .settled),
      contains: "defaults-trial3-settled.jpg", name: "snapshotFilename.basic", failures: &failures)
    expect(
      TrialSnapshotWriter.filename(label: "scheme-a/v2", trial: 1, moment: .start),
      contains: "scheme-a-v2-trial1-start.jpg", name: "snapshotFilename.sanitizesSlash",
      failures: &failures)
  }

  /// A `TrialSessionLog.TrialRecord` with all three snapshot fields set
  /// must round-trip through `Codable` unchanged.
  private static func checkSnapshotFieldsRoundTrip(_ failures: inout [Failure]) {
    let metrics = TrialOutcomeMetrics(
      tEnterSeconds: 1, tSettledSeconds: 5, overshootsX: 0, overshootsY: 0, pathIntegral: 0,
      meanAbsErrorDuringSettle: 0, timedOut: false)
    let record = TrialSessionLog.TrialRecord(
      index: 1, metrics: metrics, startSnapshot: "defaults-trial1-start.jpg",
      settledSnapshot: "defaults-trial1-settled.jpg", timeoutSnapshot: nil)
    let session = TrialSessionLog.SessionRecord(
      label: "defaults", configSource: "defaults", configHash: "abc",
      dateISO8601: "2026-08-02T00:00:00Z", settleSeconds: 2.0, timeoutSeconds: 45.0,
      displacementThreshold: 0.15, trials: [record], aggregate: nil)
    let log = TrialSessionLog(sessions: [session])

    guard let data = try? JSONEncoder().encode(log),
      let decoded = try? JSONDecoder().decode(TrialSessionLog.self, from: data)
    else {
      failures.append(
        Failure(name: "snapshotFields.roundTrip", detail: "encoding or decoding threw"))
      return
    }
    let decodedTrial = decoded.sessions.first?.trials.first
    expect(
      decodedTrial?.startSnapshot ?? "", contains: "start.jpg",
      name: "snapshotFields.startRoundTrip", failures: &failures)
    expect(
      decodedTrial?.settledSnapshot ?? "", contains: "settled.jpg",
      name: "snapshotFields.settledRoundTrip", failures: &failures)
    expect(
      decodedTrial?.timeoutSnapshot == nil, equalsBool: true,
      name: "snapshotFields.timeoutStaysNil", failures: &failures)
  }

  /// The task brief's actual backward-compatibility requirement: a
  /// pre-existing on-disk log written before `--snapshots` existed — no
  /// snapshot keys present in its JSON at all, not even as `null` — must
  /// still decode cleanly, with the new fields simply absent (`nil`).
  /// Written as a literal JSON string (not round-tripped through the
  /// current encoder) so this genuinely exercises decoding an older shape,
  /// not the current one re-decoding itself.
  private static func checkSnapshotFieldsBackwardCompatible(_ failures: inout [Failure]) {
    let oldJSON = """
      {
        "sessions": [
          {
            "label": "defaults",
            "configSource": "defaults",
            "configHash": "abc",
            "dateISO8601": "2026-08-01T00:00:00Z",
            "settleSeconds": 2.0,
            "timeoutSeconds": 45.0,
            "displacementThreshold": 0.15,
            "trials": [
              {
                "index": 1,
                "outcome": "settled",
                "tEnterSeconds": 1.0,
                "tSettledSeconds": 5.0,
                "overshootsX": 0,
                "overshootsY": 0,
                "overshootsTotal": 0,
                "pathIntegral": 0.0,
                "meanAbsErrorDuringSettle": 0.0
              }
            ],
            "aggregate": null
          }
        ]
      }
      """
    guard let data = oldJSON.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(TrialSessionLog.self, from: data)
    else {
      failures.append(
        Failure(
          name: "snapshotFields.decodesOldLog", detail: "decoding pre-snapshot-era JSON threw"))
      return
    }
    expect(
      decoded.sessions.first?.trials.count, equalsInt: 1, name: "snapshotFields.oldLogTrialCount",
      failures: &failures)
    expect(
      decoded.sessions.first?.trials.first?.startSnapshot == nil, equalsBool: true,
      name: "snapshotFields.oldLogStartNil", failures: &failures)
    expect(
      decoded.sessions.first?.trials.first?.settledSnapshot == nil, equalsBool: true,
      name: "snapshotFields.oldLogSettledNil", failures: &failures)
    expect(
      decoded.sessions.first?.trials.first?.timeoutSnapshot == nil, equalsBool: true,
      name: "snapshotFields.oldLogTimeoutNil", failures: &failures)
  }
}
