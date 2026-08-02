import AboutFaceCore
import ArgumentParser
import Foundation

/// Shared plumbing for `replay --audio` and `audition` (§13 Phase 3's "§13
/// tuning instrument" CLI): loading an optional `--config` tuning-profile
/// export, applying `--scheme`/`--scheme-b` overrides, and starting the
/// real `AudioRenderer` + `SpeechRenderer` + `FeedbackRouter(mode: .setup)`
/// — the exact same types `PipelineModel` wires into the app, so a corpus
/// clip (or an audition sound) is heard exactly as the app would render it.
enum AudioCLISupport {
  /// `--scheme <a|c>` — the two discrete positional schemes (§6.2). Scheme
  /// B is a refinement LAYER on top of Scheme A, not a third case here — see
  /// `OnOffFlag`/`--scheme-b`.
  enum SchemeFlag: String, ExpressibleByArgument, CaseIterable {
    case a
    case c
  }

  /// `--scheme-b <on|off>` — enables/disables the Scheme B percussive
  /// click-train refinement layer (§6.2, 2026-08-02 redesign — see
  /// `RenderState+SchemeB.swift`), independent of `--scheme`.
  enum OnOffFlag: String, ExpressibleByArgument, CaseIterable {
    case on
    case off

    var boolValue: Bool { self == .on }
  }

  /// `--brightness <harmonics|overdrive|saw>` (round 2, 2026-08-02): a CLI
  /// mirror of `Config.BrightnessStyle`, kept as its own type rather than
  /// making `Config.BrightnessStyle` itself `ExpressibleByArgument` because
  /// `AboutFaceCore` doesn't (and shouldn't) depend on `ArgumentParser` —
  /// same reasoning as `SchemeFlag`/`OnOffFlag` mirroring
  /// `Config.AudioPositionalScheme`/`Bool` above. Raw values match
  /// `Config.BrightnessStyle`'s exactly so `--brightness <name>` reads as
  /// the same vocabulary the Config file and the doc comments use.
  enum BrightnessFlag: String, ExpressibleByArgument, CaseIterable {
    case harmonics
    case overdrive
    case saw

    var style: Config.BrightnessStyle {
      switch self {
      case .harmonics: return .harmonics
      case .overdrive: return .overdrive
      case .saw: return .saw
      }
    }
  }

  /// Loads `Config` from `--config <path>` (a `ConfigStore.export`ed JSON
  /// tuning profile) if given, else `Config.defaults`. This is the same
  /// file format the Debug panel's Export/Import round-trips (§9) — running
  /// `replay --audio` twice with two exported profiles against the same
  /// clip is the §14 A/B workflow the task brief calls out, not a
  /// CLI-specific format.
  static func loadConfig(configPath: String?) throws -> Config {
    guard let configPath else { return .defaults }
    let url = URL(fileURLWithPath: configPath)
    return try ConfigStore.importConfig(from: url)
  }

  /// Applies `--scheme`/`--scheme-b`/`--brightness` on top of whatever
  /// `loadConfig(configPath:)` returned, so a maintainer can A/B a scheme
  /// or brightness-style change without hand-editing a profile file for
  /// every run — the exact workflow the 2026-08-02 round-2 brightness-style
  /// audition session needs (§0/§16: "tuned by ear," so make it fast to
  /// switch ears mid-session).
  static func applyOverrides(
    _ config: inout Config, scheme: SchemeFlag?, schemeB: OnOffFlag?,
    brightness: BrightnessFlag? = nil
  ) {
    if let scheme {
      config.audio.scheme.positional = scheme == .a ? .panPitch : .sequential
    }
    if let schemeB {
      config.audio.scheme.schemeBEnabled = schemeB.boolValue
    }
    if let brightness {
      config.audio.positional.brightnessStyle = brightness.style
    }
  }

  /// A no-usable-audio-device failure, with a message meant to be printed
  /// directly (never a raw `AudioRendererError` dump) — per the task
  /// brief's "degrade with a clear error when none (CI has none — that's
  /// fine, these commands aren't in tests)."
  struct AudioUnavailable: Error, CustomStringConvertible {
    let underlying: Error
    var description: String {
      "No usable audio output device available (\(underlying)). This command needs real audio "
        + "hardware to play anything — expected to fail exactly this way under CI or on a "
        + "headless machine."
    }
  }

  /// The real renderer/router trio `replay --audio` drives — a named
  /// struct rather than a 3-tuple (SwiftLint's `large_tuple`, and clearer
  /// at call sites besides).
  struct FeedbackChain: Sendable {
    let router: FeedbackRouter
    let audio: AudioRenderer
    let speech: SpeechRenderer
  }

  /// Builds and starts the real renderer/router trio for `config`. Throws
  /// `AudioUnavailable` (never crashes, never lets a raw AVFoundation error
  /// surface) if the engine can't start — callers are expected to catch
  /// this, print `error`, and exit non-zero.
  static func makeFeedbackChain(config: Config) async throws -> FeedbackChain {
    let audio = AudioRenderer(config: config.audio, mode: .realtime)
    let speech = SpeechRenderer(config: config.speech)
    do {
      try await audio.start()
    } catch {
      throw AudioUnavailable(underlying: error)
    }
    let router = FeedbackRouter(audio: audio, speech: speech, config: config, mode: .setup)
    return FeedbackChain(router: router, audio: audio, speech: speech)
  }
}
