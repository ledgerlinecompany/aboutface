import AboutFaceCore
import ArgumentParser
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `aboutface-cli verify-corpus` — the review half of the spec §14 corpus
/// tooling. For each `Fixtures/corpus/manifest.json` entry with a recorded
/// clip, replays it (unpaced) through `FileCaptureSource` -> `AnalysisEngine`,
/// aggregates per-clip statistics, and checks them against
/// `expectedCondition` with coarse heuristics (`CorpusHeuristics`).
///
/// This is TRIAGE for a human reviewer, not a CI pass/fail gate: exits 0
/// regardless of the CHECK/LOOK results unless `--strict`. Several
/// conditions (side-lit, glare) have no single scalar that settles them
/// automatically and are always flagged LOOK for a still-frame look.
struct VerifyCorpus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify-corpus",
    abstract:
      "Replay recorded spec §14 corpus clips and print a CHECK/LOOK triage table against each "
      + "clip's expectedCondition.",
    discussion: """
      For each Fixtures/corpus/manifest.json entry whose clip file exists under \
      Fixtures/corpus/clips/, replays it (unpaced, FileCaptureSource -> AnalysisEngine), \
      aggregates frame count, SignalState histogram, mean/median error.x/.y, mean \
      distanceError, mean faceLuma/backgroundLuma/backlightDelta, faceCount>1 fraction, and \
      first/middle/last sampled yaw/pitch/roll, then checks the aggregate against \
      expectedCondition with coarse heuristics documented in CorpusHeuristics.swift.

      Prints CHECK/LOOK per clip, not pass/fail: this is triage for a human reviewer, and \
      exits 0 regardless of the results unless --strict is given (which fails if any evaluated \
      clip is LOOK). A manifest entry with no clip file yet recorded is listed as MISSING and \
      is not scored either way.

      --json prints the full aggregate (not just the table's short detail string) as a JSON \
      array, one object per clip, for machine review. --stills <dir> additionally exports each \
      evaluated clip's first/middle/last frame as <NN-slug>-first.jpg / -middle.jpg / -last.jpg, \
      so a reviewer can eyeball staging without a video player.
      """
  )

  @Option(
    help: ArgumentHelp(
      "Path to the corpus fixture directory. Defaults to locating Fixtures/corpus by walking up "
        + "from the current directory."
    )
  )
  var corpusDir: String?

  @Flag(help: "Emit the full per-clip aggregate as a JSON array instead of the table.")
  var json = false

  @Option(help: "Export first/middle/last frame JPEGs of each evaluated clip into this directory.")
  var stills: String?

  @Flag(help: "Exit with a non-zero status if any evaluated clip's heuristic result is LOOK.")
  var strict = false

  func run() async throws {
    let corpusDirURL = try CorpusManifest.resolveCorpusDir(override: corpusDir)
    let manifest = try CorpusManifest.load(from: corpusDirURL)
    let clipsDir = corpusDirURL.appendingPathComponent("clips", isDirectory: true)

    var stillsDirURL: URL?
    if let stills {
      let url = URL(fileURLWithPath: stills, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      stillsDirURL = url
    }

    var rows: [ClipReport] = []
    for script in CorpusCatalog.clips {
      let entry = manifest[script.index - 1]
      let clipURL = clipsDir.appendingPathComponent(script.filename)
      rows.append(
        await evaluateClip(
          script: script, entry: entry, clipURL: clipURL, stillsDirURL: stillsDirURL))
    }

    if json {
      printJSON(rows)
    } else {
      printTable(rows)
    }

    if strict && rows.contains(where: { $0.status == .look }) {
      throw ExitCode.failure
    }
  }

  /// One manifest entry's worth of `run()`'s work — replay (if the clip
  /// exists), heuristic evaluation, and optional stills export — split out
  /// purely to keep `run()` within SwiftLint's function-body-length limit.
  private func evaluateClip(
    script: CorpusCatalog.ClipScript, entry: ManifestEntry, clipURL: URL, stillsDirURL: URL?
  ) async -> ClipReport {
    guard FileManager.default.fileExists(atPath: clipURL.path) else {
      return ClipReport(
        script: script, entry: entry, status: nil, detail: "not yet recorded", stats: nil)
    }

    let stats: ClipStats
    do {
      stats = try await replay(url: clipURL)
    } catch {
      return ClipReport(
        script: script, entry: entry, status: .look, detail: "replay failed: \(error)", stats: nil)
    }

    let (status, detail) = CorpusHeuristics.evaluate(entry: entry, stats: stats)

    if let stillsDirURL {
      do {
        try await exportStills(
          url: clipURL, frameCount: stats.frameCount, script: script, to: stillsDirURL)
      } catch {
        FileHandle.standardError.write(
          Data("Warning: could not export stills for \(script.filename): \(error)\n".utf8))
      }
    }

    return ClipReport(script: script, entry: entry, status: status, detail: detail, stats: stats)
  }

  // MARK: - Replay

  private func replay(url: URL) async throws -> ClipStats {
    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: false)
    let engine = AnalysisEngine(backend: VisionBackend())
    try await source.start()

    var stats = ClipStats()
    for await frame in source.frames {
      let output = try await engine.process(frame)
      stats.record(output)
    }
    await source.stop()
    return stats
  }

  // MARK: - Stills export

  /// A second, dedicated replay pass to grab exactly the first/middle/last
  /// frames' pixel buffers — kept separate from `replay(url:)`'s
  /// stats-gathering pass so that pass never has to hold every frame's
  /// pixel buffer in memory (only the three lightweight scalar arrays it
  /// already needs). File replay is cheap and local, so a second pass over
  /// the same clip is a fine trade for flat memory use.
  private func exportStills(
    url: URL, frameCount: Int, script: CorpusCatalog.ClipScript, to directory: URL
  ) async throws {
    guard frameCount > 0 else { return }
    var remaining: [Int: String] = [
      0: "first",
      frameCount / 2: "middle",
      frameCount - 1: "last",
    ]  // swiftlint:disable:previous trailing_comma

    let source = FileCaptureSource(url: url, pacing: .unpaced, simulateMirrored: false)
    try await source.start()

    var index = 0
    let baseName = script.filename.replacingOccurrences(of: ".mov", with: "")
    for await frame in source.frames {
      if let label = remaining.removeValue(forKey: index) {
        let destination = directory.appendingPathComponent("\(baseName)-\(label).jpg")
        try Self.writeJPEG(pixelBuffer: frame.pixelBuffer, to: destination)
        if remaining.isEmpty { break }
      }
      index += 1
    }
    await source.stop()
  }

  private enum StillsError: Error {
    case renderFailed
    case destinationFailed
    case finalizeFailed
  }

  private static func writeJPEG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      throw StillsError.renderFailed
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw StillsError.destinationFailed
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw StillsError.finalizeFailed
    }
  }

  // MARK: - Output

  private struct ClipReport {
    let script: CorpusCatalog.ClipScript
    let entry: ManifestEntry
    /// `nil` means the clip has not been recorded yet (MISSING).
    let status: ReviewStatus?
    let detail: String
    let stats: ClipStats?
  }

  private func printTable(_ rows: [ClipReport]) {
    print(
      Self.pad("#", 3) + " " + Self.pad("slug", 22) + " " + Self.pad("expected", 28) + " "
        + Self.pad("status", 7) + " detail")
    for row in rows {
      let statusText = row.status?.rawValue ?? "MISSING"
      print(
        Self.pad("\(row.script.index)", 3) + " " + Self.pad(row.script.slug, 22) + " "
          + Self.pad(row.entry.expectedCondition, 28) + " " + Self.pad(statusText, 7) + " "
          + row.detail)
    }
    let checkCount = rows.filter { $0.status == .check }.count
    let lookCount = rows.filter { $0.status == .look }.count
    let missingCount = rows.filter { $0.status == nil }.count
    print("")
    print("\(rows.count) clips: \(checkCount) CHECK, \(lookCount) LOOK, \(missingCount) missing.")
  }

  private static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
  }

  private struct ClipStatsJSON: Encodable {
    let frameCount: Int
    let stateHistogram: [String: Int]
    let meanErrorX: Float?
    let medianErrorX: Float?
    let meanErrorY: Float?
    let medianErrorY: Float?
    let meanDistanceError: Float?
    let meanFaceLuma: Float?
    let meanBackgroundLuma: Float?
    let meanBacklightDelta: Float?
    let multiFaceFraction: Double
    let firstYawPitchRoll: [Float]?
    let middleYawPitchRoll: [Float]?
    let lastYawPitchRoll: [Float]?

    init(_ stats: ClipStats) {
      frameCount = stats.frameCount
      stateHistogram = stats.stateHistogram
      meanErrorX = ClipStats.mean(stats.errorXs)
      medianErrorX = ClipStats.median(stats.errorXs)
      meanErrorY = ClipStats.mean(stats.errorYs)
      medianErrorY = ClipStats.median(stats.errorYs)
      meanDistanceError = ClipStats.mean(stats.distanceErrors)
      meanFaceLuma = ClipStats.mean(stats.faceLumas)
      meanBackgroundLuma = ClipStats.mean(stats.backgroundLumas)
      meanBacklightDelta = ClipStats.mean(stats.backlightDeltas)
      multiFaceFraction =
        stats.frameCount > 0 ? Double(stats.multiFaceFrameCount) / Double(stats.frameCount) : 0
      firstYawPitchRoll = Self.triple(stats, at: 0)
      middleYawPitchRoll = Self.triple(stats, at: stats.yaws.count / 2)
      lastYawPitchRoll = Self.triple(stats, at: stats.yaws.count - 1)
    }

    private static func triple(_ stats: ClipStats, at index: Int) -> [Float]? {
      guard index >= 0, index < stats.yaws.count, index < stats.pitches.count,
        index < stats.rolls.count
      else { return nil }
      return [stats.yaws[index], stats.pitches[index], stats.rolls[index]]
    }
  }

  private struct ClipReportJSON: Encodable {
    let index: Int
    let slug: String
    let file: String
    let description: String
    let expectedCondition: String
    let status: String
    let detail: String
    let stats: ClipStatsJSON?
  }

  private func printJSON(_ rows: [ClipReport]) {
    let payload = rows.map { row in
      ClipReportJSON(
        index: row.script.index,
        slug: row.script.slug,
        file: row.script.filename,
        description: row.entry.description,
        expectedCondition: row.entry.expectedCondition,
        status: row.status?.rawValue ?? "MISSING",
        detail: row.detail,
        stats: row.stats.map(ClipStatsJSON.init)
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) {
      print(text)
    }
  }
}
