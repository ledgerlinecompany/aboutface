import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli record-corpus` — an interactive guided recording session
/// for the spec §14 test corpus (the 20-clip list). Walks
/// `Fixtures/corpus/manifest.json` in order, one clip at a time: prints (and,
/// with `--speak`, speaks) a self-contained setup instruction, waits for
/// Return, does a 3-2-1 countdown, then records `--seconds` of video from the
/// camera to `Fixtures/corpus/clips/<NN-slug>.mov`.
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
      Return, does a 3-2-1 countdown, then records --seconds (default 15) of --width x --height \
      @ --fps video (default 1280x720@30) from the camera to \
      Fixtures/corpus/clips/<NN-slug>.mov, e.g. 01-reference.mov.

      Resumable: a clip whose target file already exists is skipped on the next run. Use \
      --redo <n> to re-record just clip n, or --all to re-record every clip regardless of what \
      already exists. After each take (including a failed one), choose:

        [Return]  keep this take (or move on despite a failure) and continue to the next clip
        r         redo this clip now
        s         skip this clip for now, without recording
        q         quit — progress so far is kept; re-run to resume

      --speak makes this the accessible recording path (AVSpeechSynthesizer, rate 0.55, default \
      voice): every printed instruction, countdown beat, and menu prompt is also spoken, in full \
      sentences that do not depend on reading anything on screen.

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

  @Option(help: "Recording duration per clip, in seconds.")
  var seconds = 15

  @Flag(
    help: ArgumentHelp(
      "Speak instructions, countdowns, and prompts via AVSpeechSynthesizer — the accessible "
        + "recording path."
    )
  )
  var speak = false

  @Option(
    help: ArgumentHelp(
      "Re-record only clip number <n> (1-20), even if it already has a file. Other "
        + "already-recorded clips are still skipped."
    )
  )
  var redo: Int?

  @Flag(help: "Re-record every clip, even ones that already have a file.")
  var all = false

  private enum TakeOutcome {
    case next
    case redo
    case skip
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
      let forceRedo = all || (redo.map { $0 == script.index } ?? false)

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
          print("\nStopping — re-run record-corpus to resume; completed clips are kept.")
          return
        case .next, .skip:
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
    await presentInstructions(script: script, entry: entry, speech: speech)
    _ = readLine()

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

    await countdown(speech: speech)

    CorpusInterruptGuard.shared.setCurrentTake(finalURL)
    let outcome: Result<CorpusRecorder.Summary, Error>
    do {
      let dimensions = CorpusRecorder.Dimensions(width: width, height: height)
      let summary = try await CorpusRecorder.record(
        source: source, dimensions: dimensions, to: finalURL, seconds: seconds
      ) { elapsedSeconds, frameCount, faces in
        let facesText = faces.map(String.init) ?? "?"
        print("t=\(elapsedSeconds)s frames=\(frameCount) faces=\(facesText)")
      }
      outcome = .success(summary)
    } catch {
      outcome = .failure(error)
    }
    CorpusInterruptGuard.shared.setCurrentTake(nil)
    await source.stop()

    reportOutcome(outcome, finalURL: finalURL)
    return await promptMenu(speech: speech)
  }

  private func presentInstructions(
    script: CorpusCatalog.ClipScript, entry: ManifestEntry, speech: Speech?
  ) async {
    var lines: [String] = []
    lines.append("Clip \(script.index) of \(CorpusCatalog.clips.count): \(entry.description)")
    lines.append(contentsOf: script.setup)
    lines.append("This will record \(seconds) seconds, starting after a 3-second countdown.")
    let prompt = "Press Return when set up."

    print("")
    print(String(repeating: "-", count: 64))
    for line in lines { print(line) }
    print(prompt)
    print(String(repeating: "-", count: 64))

    if let speech {
      await speech.speak((lines + [prompt]).joined(separator: " "))
    }
  }

  private func countdown(speech: Speech?) async {
    for n in [3, 2, 1] {
      print("\(n)...")
      if let speech {
        await speech.speak("\(n).")
      }
      try? await Task.sleep(for: .seconds(1))
    }
    print("Recording.")
    if let speech {
      await speech.speak("Recording.")
    }
  }

  private func reportOutcome(_ outcome: Result<CorpusRecorder.Summary, Error>, finalURL: URL) {
    print("")
    switch outcome {
    case .success(let summary):
      let size =
        (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? nil
      print(
        "Recorded \(String(format: "%.1f", summary.elapsedSeconds))s, \(summary.frameCount) "
          + "frames, \(Self.formatBytes(size ?? 0)) -> \(finalURL.lastPathComponent)")
    case .failure(let error):
      print("Recording failed: \(error). The clip was not saved.")
    }
  }

  private func promptMenu(speech: Speech?) async -> TakeOutcome {
    let prompt = "Return: next clip. r: redo this clip. s: skip for now. q: quit, resumable."
    print(prompt)
    if let speech {
      await speech.speak(prompt)
    }
    guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
      return .quit
    }
    switch input {
    case "":
      return .next
    case "r":
      return .redo
    case "s":
      return .skip
    case "q":
      return .quit
    default:
      print("Unrecognized input \"\(input)\" — treating as Return (next clip).")
      return .next
    }
  }

  private static func formatBytes(_ bytes: Int64) -> String {
    let megabytes = Double(bytes) / 1_048_576
    return String(format: "%.1f MB", megabytes)
  }
}
