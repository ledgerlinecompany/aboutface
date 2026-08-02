import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli audition` — the §13 tuning instrument's ear-first entry
/// point: play About Face's synthesized audio feedback directly, on demand,
/// through the real `AudioRenderer` (same renderer `PipelineModel` and
/// `replay --audio` use), without needing a corpus clip or a live camera at
/// all. This is where a maintainer's ear-tuning session starts (task
/// brief).
///
/// Needs a real audio output device — fails with a clear message (never a
/// crash) when none is available, which is expected under CI/headless
/// machines; these commands are deliberately not part of the test suite.
struct Audition: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audition",
    abstract: "Play About Face's synthesized audio feedback directly, for ear-tuning (§13).",
    discussion: """
      Three subcommands:

        audition earcon <name>   Play one named earcon once (see --help on that subcommand for \
      the full name list, e.g. `audition earcon face-lost`).
        audition sweep           Sweep the positional beacon across one axis end to end -- \
      default: horizontal error from -0.4 to +0.4 over 5s -- so pan/pitch tracking is audible in \
      one continuous pass.
        audition all             Announce each earcon by TTS name, play it, then sweep both \
      axes -- the default starting point for an ear-tuning session.

      All three take --config <path> to audition a Debug-panel-exported tuning profile instead \
      of Config.defaults, and --scheme/--scheme-b (sweep/all only) to A/B the positional scheme.
      """,
    subcommands: [AuditionEarcon.self, AuditionSweep.self, AuditionAll.self]
  )
}

/// The closed set of names `audition earcon <name>` / `audition all` speak
/// and accept — deliberately separate from (and not a substitute for)
/// `Lexicon.swift`'s §6.3 closed vocabulary, which is the SHIPPING app's
/// live-feedback speech. These are maintainer-facing diagnostic labels for
/// a CLI tool, spoken via `Speech` (see `CorpusSpeech.swift`), the same
/// "full descriptive sentences are fine here, this isn't end-user feedback"
/// TTS wrapper `record-corpus --speak` already uses.
enum EarconName: String, ExpressibleByArgument, CaseIterable {
  case enteredGoodZone = "entered-good-zone"
  case faceLost = "face-lost"
  case lowConfidence = "low-confidence"
  case noSignal = "no-signal"
  case faceReacquired = "face-reacquired"
  case heartbeat = "heartbeat"

  var event: AudioEvent {
    switch self {
    case .enteredGoodZone: return .enteredGoodZone
    case .faceLost: return .faceLost
    case .lowConfidence: return .lowConfidence
    case .noSignal: return .noSignal
    case .faceReacquired: return .faceReacquired
    case .heartbeat: return .livenessHeartbeat
    }
  }

  var announceText: String {
    switch self {
    case .enteredGoodZone: return "Entered good zone"
    case .faceLost: return "Face lost"
    case .lowConfidence: return "Low confidence"
    case .noSignal: return "No signal"
    case .faceReacquired: return "Face reacquired"
    case .heartbeat: return "Heartbeat"
    }
  }

  /// How long to let this earcon's voice ring out before stopping the
  /// engine or moving to the next one — the configured duration plus a
  /// fixed pause, computed from the SAME `Config.AudioEarcons` values the
  /// real renderer plays, so this never drifts out of sync with an earcon
  /// whose duration a maintainer has retuned via `--config`.
  func durationSeconds(config: Config.Audio) -> Double {
    let pause = 0.3
    switch self {
    case .enteredGoodZone:
      let earcon = config.earcons.enteredGoodZone
      return (earcon.noteDurationMs * 2 + earcon.gapMs) / 1000 + pause
    case .faceLost:
      return config.earcons.faceLost.durationMs / 1000 + pause
    case .lowConfidence:
      return config.earcons.lowConfidence.durationMs / 1000 + pause
    case .noSignal:
      return config.earcons.noSignal.durationMs / 1000 + pause
    case .faceReacquired:
      return config.earcons.faceReacquired.durationMs / 1000 + pause
    case .heartbeat:
      return config.heartbeat.durationMs / 1000 + pause
    }
  }
}

/// `audition sweep --axis x|y`.
enum AuditionAxis: String, ExpressibleByArgument, CaseIterable {
  case x
  case y

  // "pitch + timbre": `sweep --axis y` drives the real `AudioRenderer`
  // (`AuditionSupport.sweep` calls `audio.update(_:)` directly), so §6.2's
  // vertical-axis timbre differentiation (brightness above center,
  // darkness below, pure sine at center) is already audible in this sweep
  // with no code change beyond this label — it was only ever wired through
  // `positional.errorY`, which the sweep already drives end to end.
  var label: String { self == .x ? "horizontal (pan)" : "vertical (pitch + timbre)" }
}

/// Shared config-loading/scheme-override/sweep plumbing for the three
/// `audition` subcommands below, on top of `AudioCLISupport`'s
/// replay-and-audition-shared pieces.
enum AuditionSupport {
  static let sweepRange: ClosedRange<Float> = -0.4...0.4
  static let defaultSweepSeconds = 5.0
  /// 20 Hz — smooth enough to hear the pan/pitch sweep as continuous
  /// motion rather than discrete steps, cheap enough to not matter.
  static let sweepUpdateHz = 20.0

  /// §13 tuning instrument: "a positional sweep (errorX from -0.4 to +0.4
  /// over 5s — the beacon pan is audible end-to-end)." Drives
  /// `audio.update(_:)` directly (bypassing `FeedbackRouter` entirely,
  /// unlike `replay --audio`) since a sweep is a synthetic diagnostic
  /// signal, not a replayed `EngineOutput` stream.
  static func sweep(audio: AudioRenderer, axis: AuditionAxis, seconds: Double) async {
    let steps = max(1, Int(seconds * sweepUpdateHz))
    let stepDuration = Duration.seconds(seconds / Double(steps))
    for step in 0...steps {
      let t = Float(step) / Float(steps)
      let value = sweepRange.lowerBound + (sweepRange.upperBound - sweepRange.lowerBound) * t
      let target =
        axis == .x
        ? SonificationTarget(errorX: value, errorY: 0, distanceError: 0, inDeadZone: false)
        : SonificationTarget(errorX: 0, errorY: value, distanceError: 0, inDeadZone: false)
      await audio.update(target)
      try? await Task.sleep(for: stepDuration)
    }
    await audio.update(nil)
    try? await Task.sleep(for: .milliseconds(150))
  }

  /// Starts a real-time `AudioRenderer` for `config.audio`, or prints a
  /// clear error and throws `ExitCode.failure` (task brief: "degrade with a
  /// clear error when none"). Shared by all three subcommands below so the
  /// no-audio-device message reads identically everywhere.
  static func startRenderer(config: Config) async throws -> AudioRenderer {
    let audio = AudioRenderer(config: config.audio, mode: .realtime)
    do {
      try await audio.start()
    } catch {
      print("\(AudioCLISupport.AudioUnavailable(underlying: error))")
      throw ExitCode.failure
    }
    return audio
  }
}

struct AuditionEarcon: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "earcon",
    abstract: "Play one named earcon once.",
    discussion: "Names: \(EarconName.allCases.map(\.rawValue).joined(separator: ", "))."
  )

  @Argument(help: "Earcon name (see command discussion for the full list).")
  var name: EarconName

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile to audition instead "
        + "of Config.defaults.")
  )
  var configPath: String?

  func run() async throws {
    let config = try AudioCLISupport.loadConfig(configPath: configPath)
    let audio = try await AuditionSupport.startRenderer(config: config)
    print("Playing: \(name.announceText)")
    await audio.play(name.event)
    try? await Task.sleep(for: .seconds(name.durationSeconds(config: config.audio)))
    await audio.stop()
  }
}

struct AuditionSweep: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sweep",
    abstract: "Sweep the positional beacon across one axis, end to end."
  )

  @Option(help: "Axis to sweep: 'x' (horizontal, pan) or 'y' (vertical, pitch).")
  var axis: AuditionAxis = .x

  @Option(help: "Sweep duration in seconds.")
  var seconds = AuditionSupport.defaultSweepSeconds

  @Option(
    name: .customLong("scheme"),
    help: ArgumentHelp(
      "Override the positional sonification scheme: 'a' (pan/pitch, default) "
        + "or 'c' (sequential axis).")
  )
  var scheme: AudioCLISupport.SchemeFlag?

  @Option(
    name: .customLong("scheme-b"),
    help: ArgumentHelp("Override the Scheme B (zero-beat refinement) enable flag: 'on' or 'off'.")
  )
  var schemeB: AudioCLISupport.OnOffFlag?

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile to audition instead "
        + "of Config.defaults.")
  )
  var configPath: String?

  func run() async throws {
    var config = try AudioCLISupport.loadConfig(configPath: configPath)
    AudioCLISupport.applyOverrides(&config, scheme: scheme, schemeB: schemeB)
    let audio = try await AuditionSupport.startRenderer(config: config)

    print(
      "Sweeping \(axis.label) error from \(AuditionSupport.sweepRange.lowerBound) to "
        + "\(AuditionSupport.sweepRange.upperBound) over \(seconds)s…")
    await AuditionSupport.sweep(audio: audio, axis: axis, seconds: seconds)
    await audio.stop()
  }
}

struct AuditionAll: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "all",
    abstract: "Announce (by TTS) then play every earcon, then sweep both axes.",
    discussion: "The default starting point for an ear-tuning session."
  )

  @Option(
    name: .customLong("scheme"),
    help: ArgumentHelp(
      "Override the positional sonification scheme: 'a' (pan/pitch, default) "
        + "or 'c' (sequential axis).")
  )
  var scheme: AudioCLISupport.SchemeFlag?

  @Option(
    name: .customLong("scheme-b"),
    help: ArgumentHelp("Override the Scheme B (zero-beat refinement) enable flag: 'on' or 'off'.")
  )
  var schemeB: AudioCLISupport.OnOffFlag?

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile to audition instead "
        + "of Config.defaults.")
  )
  var configPath: String?

  func run() async throws {
    var config = try AudioCLISupport.loadConfig(configPath: configPath)
    AudioCLISupport.applyOverrides(&config, scheme: scheme, schemeB: schemeB)
    let audio = try await AuditionSupport.startRenderer(config: config)
    let announcer = Speech()

    for name in EarconName.allCases {
      print(name.announceText)
      await announcer.speak(name.announceText)
      await audio.play(name.event)
      try? await Task.sleep(for: .seconds(name.durationSeconds(config: config.audio)))
    }

    for axis in AuditionAxis.allCases {
      print("\(axis.label) sweep")
      await announcer.speak("\(axis.label) sweep")
      await AuditionSupport.sweep(
        audio: audio, axis: axis, seconds: AuditionSupport.defaultSweepSeconds)
    }

    await audio.stop()
  }
}
