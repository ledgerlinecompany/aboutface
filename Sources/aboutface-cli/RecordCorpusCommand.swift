import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli record-corpus` — an interactive guided recording session
/// for the spec §14 test corpus (the 20-clip list). Walks
/// `Fixtures/corpus/manifest.json` in order, one clip at a time: prints (and,
/// with `--speak`, speaks) a self-contained setup instruction, waits for
/// Return (or S to skip, or Q to quit), does a 3-2-1 countdown, then records
/// that clip's own duration (`--seconds` overrides every clip's duration,
/// but only when passed explicitly) of video from the camera to
/// `Fixtures/corpus/clips/<NN-slug>.mov`.
///
/// This doubles as the accessible recording path (`--speak`, via
/// `AVSpeechSynthesizer`) for a blind or low-vision contributor, since that
/// is most of this app's audience — every printed instruction has a spoken
/// equivalent, phrased to be fully actionable without looking at the
/// terminal.
struct RecordCorpus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record-corpus",
    abstract: "Interactive guided recording session for the spec §14 test corpus (20 clips).",
    discussion: """
      Walks the 20-clip list from docs/spec.md §14 / Fixtures/corpus/manifest.json one clip at a \
      time: prints (and, with --speak, speaks) a self-contained setup instruction, waits for \
      Return (or S to skip, or Q to quit), does a 3-2-1 countdown, then records that clip's own \
      duration (15 seconds for most clips; clip 14, walk-through, is 20; clip 20, \
      leave-and-return, is 25 — see CorpusCatalog.swift) of --width x --height @ --fps video \
      (default 1280x720@30) from the camera to Fixtures/corpus/clips/<NN-slug>.mov, e.g. \
      01-reference.mov. --seconds overrides every clip's duration with one fixed value, but \
      only when passed explicitly — omit it to use each clip's own duration.

      Resumable: a clip whose target file already exists is skipped on the next run. Use \
      --redo <n...> (e.g. --redo 4 9 11 13) to re-record just those clips, or --all to \
      re-record every clip regardless of what already exists.

      At the setup prompt, before recording starts:

        Start recording: press Return (after the countdown).
        Skip this clip for now, without recording: press S — useful the moment you realize a \
      clip needs staging (a second person, glasses) you don't have on hand yet.
        Quit, resumable — progress so far is kept: press Q.

      After each take (including a failed one), choose:

        Keep this take (or move on, if the take failed) and continue to the next clip: press \
      Return.
        Discard this take and redo this clip now: press R.
        Discard this take and continue to the next clip, without saving it: press D.
        Quit, resumable — progress so far is kept: press Q.

      Every choice prints (and, with --speak, speaks) an explicit confirmation of what just \
      happened — e.g. "Skipped clip 14. Nothing recorded." or "Discarded clip 14. Nothing \
      recorded." — so nothing changes silently.

      --speak makes this the accessible recording path (AVSpeechSynthesizer, rate 0.55, default \
      voice): every printed instruction, countdown beat, menu prompt, and confirmation is also \
      spoken, in full sentences that do not depend on reading anything on screen. Every \
      announcement names the function before the key that triggers it (e.g. "Skip this clip: \
      press S"), never the reverse.

      While a clip is recording, only meaningful state changes are printed (and spoken) — a \
      line when recording starts, a line each time a face is newly detected or newly lost, and \
      a line at completion with the recorded duration and the fraction of the clip a face was \
      detected — never a per-second tick. A per-second line reads as constant chatter to \
      VoiceOver, which announces every new line of terminal output as it appears.

      Safe to interrupt with Ctrl-C at any point: an in-progress take's file is removed rather \
      than left half-written, and already-completed clips are untouched.
      """
  )

  @Option(
    help: ArgumentHelp(
      "Path to the corpus fixture directory (containing manifest.json and clips/). Defaults to "
        + "locating Fixtures/corpus by walking up from the current directory."
    )
  )
  var corpusDir: String?

  @Option(
    help:
      "AVCaptureDevice.uniqueID of the camera to open. Defaults to the system default video device."
  )
  var device: String?

  @Option(help: "Requested capture width in pixels.")
  var width = 1280

  @Option(help: "Requested capture height in pixels.")
  var height = 720

  @Option(help: "Requested capture frame rate in fps.")
  var fps: Double = 30

  @Option(
    help: ArgumentHelp(
      "Override recording duration for every clip, in seconds. Applied to ALL clips only when "
        + "passed explicitly; otherwise each clip uses its own duration from CorpusCatalog "
        + "(15s for most clips; clip 14, walk-through, is 20s; clip 20, leave-and-return, is 25s)."
    )
  )
  var seconds: Int?

  @Flag(
    help: ArgumentHelp(
      "Speak instructions, countdowns, and prompts via AVSpeechSynthesizer — the accessible "
        + "recording path."
    )
  )
  var speak = false

  @Option(
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Re-record only these clip numbers (1-20), even if they already have files — space-"
        + "separated (--redo 4 9 11 13) or repeated (--redo 4 --redo 9). Other already-"
        + "recorded clips are still skipped."
    )
  )
  var redo: [Int] = []

  @Flag(help: "Re-record every clip, even ones that already have a file.")
  var all = false

  /// `.advance` covers every "move on to the next clip" path — a kept
  /// take, a discarded take, and a clip skipped at the setup prompt all
  /// return it; what actually happened was already printed/spoken by
  /// whichever prompt produced it, so `run()`'s dispatch doesn't need to
  /// distinguish them further.
  private enum TakeOutcome {
    case advance
    case redo
    case quit
    case cameraUnavailable
  }

  func run() async throws {
    guard makeSource() != nil else {
      print(
        "No camera available: no default video device was found (e.g. headless CI/no hardware).")
      throw ExitCode.failure
    }

    let corpusDirURL = try CorpusManifest.resolveCorpusDir(override: corpusDir)
    let manifest = try CorpusManifest.load(from: corpusDirURL)
    let clipsDir = corpusDirURL.appendingPathComponent("clips", isDirectory: true)
    try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)

    let speech = speak ? Speech() : nil
    CorpusInterruptGuard.shared.install()

    print(
      "About Face corpus recorder — \(CorpusCatalog.clips.count) clips. "
        + "Ctrl-C at any time to stop; progress is kept.")

    clipLoop: for script in CorpusCatalog.clips {
      let entry = manifest[script.index - 1]
      let finalURL = clipsDir.appendingPathComponent(script.filename)
      let forceRedo = all || redo.contains(script.index)

      if FileManager.default.fileExists(atPath: finalURL.path) && !forceRedo {
        print(
          "Clip \(script.index) of \(CorpusCatalog.clips.count) (\(script.slug)): "
            + "already recorded, skipping. Use --redo \(script.index) or --all to re-record.")
        continue
      }

      while true {
        let outcome = await runTake(
          script: script, entry: entry, finalURL: finalURL, speech: speech)
        switch outcome {
        case .redo:
          continue
        case .cameraUnavailable:
          throw ExitCode.failure
        case .quit:
          print("")
          await announce(
            "Stopping — re-run record-corpus to resume; completed clips are kept.",
            speech: speech)
          return
        case .advance:
          continue clipLoop
        }
      }
    }

    print("\nAll \(CorpusCatalog.clips.count) clips processed.")
  }

  private func makeSource() -> CameraCaptureSource? {
    if let device {
      return CameraCaptureSource(
        deviceUniqueID: device, width: width, height: height, frameRate: fps)
    }
    return CameraCaptureSource.defaultDevice(width: width, height: height, frameRate: fps)
  }

  // MARK: - One clip's take

  private func runTake(
    script: CorpusCatalog.ClipScript,
    entry: ManifestEntry,
    finalURL: URL,
    speech: Speech?
  ) async -> TakeOutcome {
    let clipSeconds = seconds ?? script.durationSeconds
    await presentInstructions(
      script: script, entry: entry, clipSeconds: clipSeconds, speech: speech)

    switch await readSetupInput(speech: speech) {
    case .skip:
      await announce("Skipped clip \(script.index). Nothing recorded.", speech: speech)
      return .advance
    case .quit:
      return .quit
    case .start:
      break
    }

    guard let source = makeSource() else {
      print(
        "No camera available: no default video device was found (e.g. headless CI/no hardware).")
      return .cameraUnavailable
    }

    do {
      try await source.start()
    } catch {
      print(
        "Could not start capture: \(error). If this is a permission problem, grant camera access "
          + "in System Settings > Privacy & Security > Camera and try again.")
      return .cameraUnavailable
    }

    await countdown(script: script, clipSeconds: clipSeconds, speech: speech)

    let outcome = await recordTake(
      source: source, finalURL: finalURL, clipSeconds: clipSeconds, speech: speech)
    await source.stop()

    await reportOutcome(outcome, speech: speech)
    return await handlePostRecordChoice(
      script: script, finalURL: finalURL, outcome: outcome, speech: speech)
  }

  /// Runs one take's `CorpusRecorder.record` call under
  /// `CorpusInterruptGuard`'s tracking — split out of `runTake` purely to
  /// keep that function within SwiftLint's body-length/complexity limits,
  /// not a separately reusable piece.
  private func recordTake(
    source: CameraCaptureSource, finalURL: URL, clipSeconds: Int, speech: Speech?
  ) async -> Result<CorpusRecorder.Summary, Error> {
    CorpusInterruptGuard.shared.setCurrentTake(finalURL)
    defer { CorpusInterruptGuard.shared.setCurrentTake(nil) }
    do {
      let dimensions = CorpusRecorder.Dimensions(width: width, height: height)
      let summary = try await CorpusRecorder.record(
        source: source, dimensions: dimensions, to: finalURL, seconds: clipSeconds
      ) { faceDetected in
        let line = faceDetected ? "Face detected." : "Face lost."
        await announce(line, speech: speech)
      }
      return .success(summary)
    } catch {
      return .failure(error)
    }
  }

  /// The post-take menu's key handling and confirmation, split out of
  /// `runTake` purely to keep that function within SwiftLint's
  /// body-length/complexity limits — see `promptPostRecord`'s doc comment
  /// (`RecordCorpusPrompts.swift`) for the behavior this implements.
  private func handlePostRecordChoice(
    script: CorpusCatalog.ClipScript, finalURL: URL, outcome: Result<CorpusRecorder.Summary, Error>,
    speech: Speech?
  ) async -> TakeOutcome {
    switch await promptPostRecord(script: script, finalURL: finalURL, speech: speech) {
    case .keep:
      let line: String
      switch outcome {
      case .success:
        line = "Kept clip \(script.index): \(finalURL.lastPathComponent)."
      case .failure:
        line = "Moving on. Clip \(script.index) was not recorded."
      }
      await announce(line, speech: speech)
      return .advance
    case .redo:
      try? FileManager.default.removeItem(at: finalURL)
      await announce("Redoing clip \(script.index).", speech: speech)
      return .redo
    case .discard:
      try? FileManager.default.removeItem(at: finalURL)
      await announce("Discarded clip \(script.index). Nothing recorded.", speech: speech)
      return .advance
    case .quit:
      return .quit
    }
  }
}
