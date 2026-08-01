import AboutFaceCore
import Darwin

// Headless harness (§13, Phase 1): runs camera or corpus clip input through
// AboutFaceCore and prints FrameAnalysis. No UI, no audio at this phase.
//
// This is a placeholder entry point for package scaffolding. Corpus replay
// and live capture wiring land with the rest of Phase 1 (capture session,
// AnalysisEngine, and real VisionBackend inference).

let name = "aboutface-cli"
let version = "0.0.0-phase1"
let configVersion = Config.defaults.version

print("\(name) \(version) (Config schema v\(configVersion))")
print("Usage: \(name) [--camera | --corpus <clip-path>]")
print("  Corpus replay and live capture are not implemented yet — Phase 1 scaffolding only.")

exit(0)
