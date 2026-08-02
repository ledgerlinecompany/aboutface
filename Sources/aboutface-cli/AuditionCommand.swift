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
      one continuous pass. --axis distance sweeps distanceError instead (too far -> correct -> \
      too close), with a spoken/printed marker at each third so the directional pulse character \
      (sharp chops too close, smooth swell too far, steady at target) is easy to place by ear. \
      `--axis gaze-yaw`/`gaze-pitch` sweep the gaze-trim prototype (-20 to +20 degrees) \
      directly through the renderer's trim mode.
        audition all             Announce each earcon by TTS name, play it, then sweep the three \
      beacon axes (x, y, distance) -- the default starting point for an ear-tuning session. Does \
      not include the gaze-trim axes; audition those with `sweep --axis gaze-yaw`/`gaze-pitch`.

      All three take --config <path> to audition a Debug-panel-exported tuning profile instead \
      of Config.defaults, and --scheme/--scheme-b (sweep/all only) to A/B the positional scheme. \
      `sweep --axis y` additionally takes --brightness <harmonics|overdrive|saw> to A/B the \
      vertical-timbre "target above" brightness style without editing a config file.
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

  @Option(
    help: ArgumentHelp(
      "Axis to sweep: 'x' (horizontal, pan), 'y' (vertical, pitch), 'distance' "
        + "(pulse rate + directional character), or 'gaze-yaw'/'gaze-pitch' "
        + "(gaze-trim prototype, -20 to +20 degrees, in trim mode).")
  )
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
    help: ArgumentHelp(
      "Override the Scheme B (percussive click refinement) enable flag: 'on' or 'off'.")
  )
  var schemeB: AudioCLISupport.OnOffFlag?

  // 2026-08-02 round-2 audition session: "make the brightness CHARACTER
  // selectable so the maintainer auditions all three and picks by ear."
  // `sweep --axis y` is exactly where the above-target brightness
  // ingredient is audible (the vertical tone's timbre), so this override
  // lets the maintainer A/B `.harmonics`/`.overdrive`/`.saw` back to back
  // without hand-editing/re-exporting a `--config` profile between runs.
  @Option(
    name: .customLong("brightness"),
    help: ArgumentHelp(
      "Override the vertical-timbre brightness ('target above') style: "
        + "'harmonics' (round-1 baseline), 'overdrive' (shipped default), or 'saw'.")
  )
  var brightness: AudioCLISupport.BrightnessFlag?

  @Option(
    name: .customLong("config"),
    help: ArgumentHelp(
      "Path to a ConfigStore-exported JSON tuning profile to audition instead "
        + "of Config.defaults.")
  )
  var configPath: String?

  func run() async throws {
    var config = try AudioCLISupport.loadConfig(configPath: configPath)
    AudioCLISupport.applyOverrides(
      &config, scheme: scheme, schemeB: schemeB, brightness: brightness)
    let audio = try await AuditionSupport.startRenderer(config: config)

    print(AuditionSupport.sweepHeader(axis: axis, seconds: seconds))
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
    help: ArgumentHelp(
      "Override the Scheme B (percussive click refinement) enable flag: 'on' or 'off'.")
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

    // Tuning round 5: `AuditionAxis.allCases` also includes the two
    // gaze-trim axes now (`sweep --axis gaze-yaw`/`gaze-pitch`), but this
    // round's brief is explicit that `audition all`'s existing x/y sweep
    // pair stays unchanged — the gaze-trim prototype is auditioned via
    // `sweep` directly, not folded into the default ear-tuning pass.
    for axis in AuditionAxis.allCases where !axis.isGazeTrim {
      print("\(axis.label) sweep")
      await announcer.speak("\(axis.label) sweep")
      await AuditionSupport.sweep(
        audio: audio, axis: axis, seconds: AuditionSupport.defaultSweepSeconds,
        announcer: announcer)
    }

    await audio.stop()
  }
}
