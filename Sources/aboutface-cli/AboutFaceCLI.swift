import AboutFaceCore
import ArgumentParser

/// Headless harness entry point (§13, Phase 1: "test corpus harness. Emits
/// `FrameAnalysis` to console. No UI, no audio."). Two subcommands:
///
/// - `replay` — corpus/file replay through `AnalysisEngine` (§14 harness).
///   `replay --audio` (§13 Phase 3) plays that replay's feedback through a
///   real `AudioRenderer`/`SpeechRenderer`/`FeedbackRouter`.
/// - `live` — live camera through `AnalysisEngine`, the §13 Phase 1
///   acceptance probe for "runs a live camera at 30Hz without dropping
///   frames."
/// - `audition` — play About Face's synthesized audio feedback directly
///   (earcons by name, a positional sweep, or both) without needing a
///   corpus clip: the §13 ear-tuning entry point.
///
/// Not named `main.swift`, deliberately: `@main` and the implicit top-level
/// executable semantics of a file literally named `main.swift` are mutually
/// exclusive, and `AsyncParsableCommand`'s generated `static func main()
/// async` is the entry point here.
///
/// Two more subcommands support building the §14 test corpus itself:
///
/// - `record-corpus` — interactive guided recording session for the 20-clip
///   list (also the accessible, `--speak`-driven recording path).
/// - `verify-corpus` — replays recorded clips and prints a CHECK/LOOK
///   triage table against each clip's expected condition.
/// - `trial` — the maintainer's proposed convergence-trial harness: live
///   camera + the real audio feedback chain, repeated-measures timing of
///   how quickly and consistently the maintainer reaches the ideal
///   viewing position, with `--config` as the tuning-profile A/B
///   mechanism. See `TrialCommand.swift`.
@main
struct AboutFaceCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "aboutface-cli",
    abstract: "About Face headless harness: replay a corpus clip or run a live camera through "
      + "AnalysisEngine and print FrameAnalysis to the console, optionally with real audio "
      + "feedback (§13 Phase 3).",
    version: "0.0.0-phase3 (Config schema v\(Config.defaults.version))",
    subcommands: [
      Replay.self, Live.self, Audition.self, RecordCorpus.self, VerifyCorpus.self, Trial.self,
      ConfigDefaults.self,
    ]  // swiftlint:disable:previous trailing_comma
  )
}
