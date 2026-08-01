import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli replay <path>` — the §14 corpus-harness half of Phase 1's
/// "test corpus harness. Emits `FrameAnalysis` to console" acceptance
/// criterion. Feeds a `FileCaptureSource` through `AnalysisEngine` and
/// prints one line per frame, then a summary.
///
/// `--audio` (§13 Phase 3) turns this into the §13 tuning instrument: paced,
/// real-time replay driving the SAME `AnalysisEngine` output into a real
/// `FeedbackRouter(mode: .setup)` + `AudioRenderer` + `SpeechRenderer` — the
/// exact renderer/router types `PipelineModel` wires into the app — so a
/// corpus clip is HEARD exactly as the app would render it, not simulated.
struct Replay: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "replay",
    abstract:
      "Replay a video file through AnalysisEngine and print FrameAnalysis, one line per frame.",
    discussion: """
      Plain-text output (default): one line per frame, space-separated fields in this fixed order:

        <timestampSeconds> <signalState> faces=<faceCount> err=<x>,<y> dist=<distanceError> \
      dz=<inDeadZone> ypr=<yaw>,<pitch>,<roll> luma=<faceLuma>,<backgroundLuma> conf=<confidence>

      Fields that depend on a detected face (err, dist, dz, ypr, conf) print "-" on a frame with \
      no face. After the last frame, a blank line, then a summary block: total frame count, a \
      signalState histogram, and the mean of |error.x| / |error.y| over frames that had a face.

      Pass --json for one JSON object per line instead (same fields; explicit null instead of "-"; \
      every key present on every line regardless of signalState). Key ORDER is not part of the \
      contract -- look fields up by name. No summary block is printed after JSON output, so a \
      script can pipe stdout straight into a JSON-lines parser without special-casing a trailing \
      non-JSON block.

      --audio (§13 Phase 3): plays the clip's feedback through a real AudioRenderer + \
      SpeechRenderer + FeedbackRouter(mode: .setup), paced at the clip's real-time rate (implies \
      --paced) so timing-sensitive behavior -- dwell, hysteresis, the heartbeat, the face-lost \
      ladder -- sounds the way it would live. Needs a real audio output device; fails with a \
      clear message (not a crash) when none is available, which is expected under CI. \
      Per-frame text output is suppressed by default under --audio (one status line per second \
      instead) since the point is to LISTEN; pass --verbose to keep the full per-frame lines too. \
      --scheme/--scheme-b/--config let you A/B two tuning profiles against the identical clip \
      (the §14 workflow): run replay --audio twice, once per --config, and compare by ear. \
      --silence-at <sec> engages the §7.5 manual-silence path partway through the clip, so that \
      "cuts within one buffer, analysis keeps running" behavior is audible too.
      """
  )

  @Argument(help: "Path to a video file (any AVFoundation-readable container/codec).")
  var path: String

  @Flag(
    help: ArgumentHelp(
      "Simulate a mirrored capture by flipping the clip's pixels before analysis "
        + "(§3.4 mirror-convention acceptance testing)."
    )
  )
  var simulateMirrored = false

  @Flag(help: "Pace frame delivery at the clip's real-time rate instead of as fast as possible.")
  var paced = false

  @Flag(help: "Emit one JSON object per line instead of the plain-text format.")
  var json = false

  @Flag(
    name: .customLong("audio"),
    help: ArgumentHelp(
      "Play the clip's feedback through a real AudioRenderer/SpeechRenderer/FeedbackRouter "
        + "(§13 Phase 3) as it replays. Implies --paced. Needs a real audio output device."
    )
  )
  var audioEnabled = false

  @Option(
    name: .customLong("scheme"),
    help: ArgumentHelp(
      "Override the positional sonification scheme for --audio: 'a' (pan/pitch, default) or "
        + "'c' (sequential axis)."
    )
  )
  var scheme: AudioCLISupport.SchemeFlag?

  @Option(
    name: .customLong("scheme-b"),
    help: ArgumentHelp(
      "Override the Scheme B (zero-beat refinement) enable flag for --audio: 'on' or 'off'.")
  )
  var schemeB: AudioCLISupport.OnOffFlag?

  @Option(
    name: .customLong("silence-at"),
    help: ArgumentHelp(
      "With --audio, engage §7.5 manual silence once the clip reaches this many seconds "
        + "(clip-relative timestamp). Analysis keeps running; only the feedback goes silent."
    )
  )
  var silenceAt: Double?

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile (Debug panel Export…) to replay "
        + "against, instead of Config.defaults. Only affects --audio."
    )
  )
  var configPath: String?

  @Flag(
    help: ArgumentHelp(
      "With --audio, also print the normal per-frame text/JSON lines (suppressed by default "
        + "under --audio, since the point is to listen). No effect without --audio."
    )
  )
  var verbose = false

  func run() async throws {
    let url = URL(fileURLWithPath: path)
    let effectivePaced = paced || audioEnabled
    let pacing: FileCaptureSource.PacingMode = effectivePaced ? .realTime : .unpaced
    let source = FileCaptureSource(url: url, pacing: pacing, simulateMirrored: simulateMirrored)
    let engine = AnalysisEngine(backend: VisionBackend())

    try await source.start()

    if audioEnabled {
      try await runWithAudio(source: source, engine: engine)
    } else {
      try await runPlain(source: source, engine: engine)
    }

    await source.stop()
  }

  // MARK: - Plain replay (existing behavior, unchanged)

  private func runPlain(source: FileCaptureSource, engine: AnalysisEngine) async throws {
    var frameCount = 0
    var stateHistogram: [String: Int] = [:]
    var absErrorXSum: Float = 0
    var absErrorYSum: Float = 0
    var errorSampleCount = 0

    for try await output in engine.stream(from: source) {
      frameCount += 1
      let line = OutputLine(output)
      stateHistogram[line.signalState, default: 0] += 1
      if let framing = output.framing {
        absErrorXSum += abs(framing.error.x)
        absErrorYSum += abs(framing.error.y)
        errorSampleCount += 1
      }
      print(json ? line.jsonString() : line.plainText())
    }

    guard !json else { return }
    printSummary(
      frameCount: frameCount,
      stateHistogram: stateHistogram,
      absErrorXSum: absErrorXSum,
      absErrorYSum: absErrorYSum,
      errorSampleCount: errorSampleCount
    )
  }

  // MARK: - --audio replay (§13 Phase 3)

  private func runWithAudio(source: FileCaptureSource, engine: AnalysisEngine) async throws {
    var config = try AudioCLISupport.loadConfig(configPath: configPath)
    AudioCLISupport.applyOverrides(&config, scheme: scheme, schemeB: schemeB)

    let chain: AudioCLISupport.FeedbackChain
    do {
      chain = try await AudioCLISupport.makeFeedbackChain(config: config)
    } catch {
      print("\(error)")
      throw ExitCode.failure
    }

    var frameCount = 0
    var stateHistogram: [String: Int] = [:]
    var absErrorXSum: Float = 0
    var absErrorYSum: Float = 0
    var errorSampleCount = 0
    var lastReportedSecond = -1
    var silenceEngaged = false

    for try await output in engine.stream(from: source) {
      frameCount += 1
      let line = OutputLine(output)
      stateHistogram[line.signalState, default: 0] += 1
      if let framing = output.framing {
        absErrorXSum += abs(framing.error.x)
        absErrorYSum += abs(framing.error.y)
        errorSampleCount += 1
      }

      if verbose {
        print(json ? line.jsonString() : line.plainText())
      } else {
        let wholeSecond = Int(line.timestampSeconds)
        if wholeSecond != lastReportedSecond {
          lastReportedSecond = wholeSecond
          print("t=\(wholeSecond)s \(line.signalState) faces=\(line.faceCount)")
        }
      }

      if let silenceAt, !silenceEngaged, line.timestampSeconds >= silenceAt {
        silenceEngaged = true
        await chain.router.setSilenced(true)
        print("-- §7.5 manual silence engaged at t=\(String(format: "%.2f", silenceAt))s --")
      }

      await chain.router.ingest(output, at: .now)
    }

    await chain.audio.stop()

    guard !json else { return }
    printSummary(
      frameCount: frameCount,
      stateHistogram: stateHistogram,
      absErrorXSum: absErrorXSum,
      absErrorYSum: absErrorYSum,
      errorSampleCount: errorSampleCount
    )
  }

  private func printSummary(
    frameCount: Int,
    stateHistogram: [String: Int],
    absErrorXSum: Float,
    absErrorYSum: Float,
    errorSampleCount: Int
  ) {
    print("")
    print("frames=\(frameCount)")
    for (state, count) in stateHistogram.sorted(by: { $0.key < $1.key }) {
      print("  \(state)=\(count)")
    }
    if errorSampleCount > 0 {
      let meanAbsX = absErrorXSum / Float(errorSampleCount)
      let meanAbsY = absErrorYSum / Float(errorSampleCount)
      print(
        "meanAbsError x=\(String(format: "%.4f", meanAbsX)) y=\(String(format: "%.4f", meanAbsY)) "
          + "(over \(errorSampleCount) frames with a detected face)")
    } else {
      print("meanAbsError: no frames with a detected face")
    }
  }
}
