import AboutFaceCore
import ArgumentParser

/// Headless harness entry point (§13, Phase 1: "test corpus harness. Emits
/// `FrameAnalysis` to console. No UI, no audio."). Two subcommands:
///
/// - `replay` — corpus/file replay through `AnalysisEngine` (§14 harness).
/// - `live` — live camera through `AnalysisEngine`, the §13 Phase 1
///   acceptance probe for "runs a live camera at 30Hz without dropping
///   frames."
///
/// Not named `main.swift`, deliberately: `@main` and the implicit top-level
/// executable semantics of a file literally named `main.swift` are mutually
/// exclusive, and `AsyncParsableCommand`'s generated `static func main()
/// async` is the entry point here.
@main
struct AboutFaceCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "aboutface-cli",
    abstract: "About Face headless harness (§13 Phase 1): replay a corpus clip or run a live "
      + "camera through AnalysisEngine and print FrameAnalysis to the console.",
    version: "0.0.0-phase1 (Config schema v\(Config.defaults.version))",
    subcommands: [Replay.self, Live.self]
  )
}
