import Foundation

/// `RecordCorpus`'s prompt/menu/announcement plumbing — split out of
/// `RecordCorpusCommand.swift` purely to keep that file and its type body
/// within SwiftLint's length limits, not a separately reusable surface.
/// Every function here follows two rules from the task brief that produced
/// this file: an announcement names the function before the key that
/// triggers it ("Skip this clip: press S", never "s: skip this clip"), and
/// every state-changing choice prints (and, with `--speak`, speaks) an
/// explicit confirmation of what just happened — no silent state changes.
extension RecordCorpus {
  enum SetupOutcome {
    case start
    case skip
    case quit
  }

  enum PostRecordOutcome {
    case keep
    case redo
    case discard
    case quit
  }

  func presentInstructions(
    script: CorpusCatalog.ClipScript, entry: ManifestEntry, clipSeconds: Int, speech: Speech?
  ) async {
    var lines: [String] = []
    lines.append("Clip \(script.index) of \(CorpusCatalog.clips.count): \(entry.description)")
    lines.append(contentsOf: script.setup)
    lines.append("This will record \(clipSeconds) seconds, starting after a 3-second countdown.")
    let prompt = "Start: press Return. Skip this clip: press S. Quit, resumable: press Q."

    print("")
    print(String(repeating: "-", count: 64))
    for line in lines { print(line) }
    print(prompt)
    print(String(repeating: "-", count: 64))

    if let speech {
      await speech.speak((lines + [prompt]).joined(separator: " "))
    }
  }

  /// The setup prompt's key handling (task brief #2): unlike the old
  /// behavior where ANY keypress started recording, this must recognize S
  /// (skip) and Q (quit) explicitly, since a clip that cannot be staged
  /// solo (second person, glasses) needs to be skippable at the exact
  /// moment the contributor realizes that — not only after sitting through
  /// a take that was never going to work.
  func readSetupInput(speech: Speech?) async -> SetupOutcome {
    guard let rawInput = readLine() else { return .quit }
    let input = rawInput.trimmingCharacters(in: .whitespaces).lowercased()
    switch input {
    case "":
      return .start
    case "s":
      return .skip
    case "q":
      return .quit
    default:
      await announce("Unrecognized input \"\(input)\" — starting anyway.", speech: speech)
      return .start
    }
  }

  func countdown(script: CorpusCatalog.ClipScript, clipSeconds: Int, speech: Speech?) async {
    for n in [3, 2, 1] {
      print("\(n)...")
      if let speech {
        await speech.speak("\(n).")
      }
      try? await Task.sleep(for: .seconds(1))
    }
    await announce("Recording clip \(script.index), \(clipSeconds) seconds.", speech: speech)
  }

  /// The one completion line for a take (task brief #3): no per-second
  /// ticks, just what changed (recorded/failed) and, on success, the
  /// fraction of the take a face was actually detected in — the same
  /// signal the old per-second `faces=N` chatter existed to give, just
  /// reported once instead of every second.
  func reportOutcome(
    _ outcome: Result<CorpusRecorder.Summary, Error>, speech: Speech?
  ) async {
    switch outcome {
    case .success(let summary):
      let elapsed = Int(summary.elapsedSeconds.rounded())
      let line: String
      if let fraction = summary.faceDetectedFraction {
        let percent = Int((fraction * 100).rounded())
        line = "Done. \(elapsed) seconds recorded, face detected \(percent)% of frames."
      } else {
        line = "Done. \(elapsed) seconds recorded."
      }
      await announce(line, speech: speech)
    case .failure(let error):
      await announce("Recording failed: \(error). The clip was not saved.", speech: speech)
    }
  }

  /// The post-take menu (task brief #2): 's' used to be indistinguishable
  /// from Return — both fell through to the same "continue to the next
  /// clip" branch in the old `run()`, so a saved take was never actually
  /// discarded no matter which key was pressed, and nothing printed said
  /// so either way. 'd' (discard) now actually deletes the file it applies
  /// to, and every branch announces what happened.
  func promptPostRecord(
    script: CorpusCatalog.ClipScript, finalURL: URL, speech: Speech?
  ) async -> PostRecordOutcome {
    let prompt =
      "Keep and continue: press Return. Redo: press R. Discard this take: press D. "
      + "Quit, resumable: press Q."
    print(prompt)
    if let speech {
      await speech.speak(prompt)
    }
    guard let rawInput = readLine() else { return .quit }
    let input = rawInput.trimmingCharacters(in: .whitespaces).lowercased()
    switch input {
    case "":
      return .keep
    case "r":
      return .redo
    case "d":
      return .discard
    case "q":
      return .quit
    default:
      await announce(
        "Unrecognized input \"\(input)\" — keeping this take and continuing.", speech: speech)
      return .keep
    }
  }

  func announce(_ text: String, speech: Speech?) async {
    print(text)
    if let speech {
      await speech.speak(text)
    }
  }
}
