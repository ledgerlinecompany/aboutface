import AboutFaceCore
import ArgumentParser
import Foundation

/// `AuditionAxis`/`AuditionSupport` — split out of `AuditionCommand.swift`
/// purely to stay under SwiftLint's `file_length` (same reasoning behind
/// every other `X+Y.swift` split in this codebase, e.g.
/// `Config+AudioGazeTrim.swift`). `AuditionCommand.swift`'s three
/// `AsyncParsableCommand`s (`AuditionEarcon`/`AuditionSweep`/`AuditionAll`)
/// are still the only public entry points; everything here is shared
/// plumbing they call into.

/// `audition sweep --axis x|y|distance|gaze-yaw|gaze-pitch`.
enum AuditionAxis: String, ExpressibleByArgument, CaseIterable {
  case x
  case y
  /// Round-4 directional-distance: sweeps `distanceError` so the pulse
  /// rate-plus-character encoding (sharp chops too close, smooth swell too
  /// far, steady at target) is audible end to end; `DistanceMarker` below
  /// provides the printed/spoken too-far/correct/too-close third markers.
  case distance
  /// Tuning round 5 (maintainer-designed gaze-trim prototype, default
  /// OFF — see `Config.AudioGazeTrim`): sweeps `yawDeviationDegrees`
  /// through the real renderer in trim mode, bypassing `FeedbackRouter`
  /// entirely (same posture as `x`/`y` below) so the trim tone is
  /// auditionable without flipping the config flag or getting a face in
  /// front of a camera at all.
  case gazeYaw = "gaze-yaw"
  /// Sweeps `pitchDeviationDegrees` the same way.
  case gazePitch = "gaze-pitch"

  // "pitch + timbre": `sweep --axis y` drives the real `AudioRenderer`
  // (`AuditionSupport.sweep` calls `audio.update(_:)` directly), so §6.2's
  // vertical-axis timbre differentiation (brightness above center,
  // darkness below, pure sine at center) is already audible in this sweep
  // with no code change beyond this label — it was only ever wired through
  // `positional.errorY`, which the sweep already drives end to end.
  var label: String {
    switch self {
    case .x: return "horizontal (pan)"
    case .y: return "vertical (pitch + timbre)"
    case .distance: return "distance (pulse rate + directional character)"
    case .gazeYaw: return "gaze trim yaw (pan)"
    case .gazePitch: return "gaze trim pitch (register)"
    }
  }

  /// `AuditionAll.run()` filters these out (see its own doc comment) so
  /// `audition all`'s existing x/y sweep pair stays exactly as it was —
  /// the task brief for this round is explicit that "existing axes [are]
  /// unchanged."
  var isGazeTrim: Bool {
    switch self {
    case .x, .y, .distance: return false
    case .gazeYaw, .gazePitch: return true
    }
  }
}

/// Shared config-loading/scheme-override/sweep plumbing for the three
/// `audition` subcommands, on top of `AudioCLISupport`'s
/// replay-and-audition-shared pieces.
enum AuditionSupport {
  static let sweepRange: ClosedRange<Float> = -0.4...0.4
  /// Tuning round 5 (gaze-trim prototype): degrees, matching
  /// `Config.AudioGazeTrim.deviationRangeDegrees`'s default full-scale
  /// value so a default-config sweep exercises the trim mapping end to
  /// end (beyond its clamp point, not just up to it).
  static let gazeTrimSweepRangeDegrees: ClosedRange<Float> = -20...20
  static let defaultSweepSeconds = 5.0
  /// 20 Hz — smooth enough to hear the pan/pitch sweep as continuous
  /// motion rather than discrete steps, cheap enough to not matter.
  static let sweepUpdateHz = 20.0

  /// §13 tuning instrument: "a positional sweep (errorX from -0.4 to +0.4
  /// over 5s — the beacon pan is audible end-to-end)." Drives
  /// `audio.update(_:)` directly (bypassing `FeedbackRouter` entirely,
  /// unlike `replay --audio`) since a sweep is a synthetic diagnostic
  /// signal, not a replayed `EngineOutput` stream. Tuning round 5 extends
  /// this the same way for the two gaze-trim axes — see
  /// `sweepTarget(axis:t:)`.
  static func sweep(
    audio: AudioRenderer, axis: AuditionAxis, seconds: Double, announcer: Speech? = nil
  ) async {
    let steps = max(1, Int(seconds * sweepUpdateHz))
    let stepDuration = Duration.seconds(seconds / Double(steps))
    // Markers at each third of the sweep so a maintainer listening without
    // a stopwatch can tell roughly where in the range they are — most
    // useful for the wider, less-familiar gaze-trim degree range, printed
    // for every axis for consistency. The distance axis instead speaks and
    // prints its named condition markers (too far / correct / too close)
    // whenever the swept value crosses into a new third — dedup'd via
    // `DistanceMarker`, matching the round-4 behavior.
    let markerSteps: Set<Int> = [0, steps / 3, (2 * steps) / 3, steps]
    var lastMarker: DistanceMarker?
    for step in 0...steps {
      let t = Float(step) / Float(steps)
      if axis == .distance {
        let marker = DistanceMarker(distanceError: lerp(sweepRange, t), range: sweepRange)
        if marker != lastMarker {
          print("  \(marker.text)")
          await announcer?.speak(marker.text)
          lastMarker = marker
        }
      } else if markerSteps.contains(step) {
        print("  \(markerLabel(axis: axis, t: t))")
      }
      await audio.update(sweepTarget(axis: axis, t: t))
      try? await Task.sleep(for: stepDuration)
    }
    await audio.update(nil)
    try? await Task.sleep(for: .milliseconds(150))
  }

  /// The swept `SonificationTarget` at normalized sweep position `t`
  /// (`0...1`). `x`/`y` drive the beacon's `errorX`/`errorY`, unchanged
  /// from before this round; `gazeYaw`/`gazePitch` drive the trim
  /// register directly (`gazeTrimActive: true`, `inDeadZone: true` —
  /// matching what `FeedbackRouter.gazeTrimTarget(output:framing:)`
  /// publishes in real operation) so the real renderer plays the real
  /// trim tone, not a beacon reading mislabeled.
  private static func sweepTarget(axis: AuditionAxis, t: Float) -> SonificationTarget {
    switch axis {
    case .x:
      let value = lerp(sweepRange, t)
      return SonificationTarget(errorX: value, errorY: 0, distanceError: 0, inDeadZone: false)
    case .y:
      let value = lerp(sweepRange, t)
      return SonificationTarget(errorX: 0, errorY: value, distanceError: 0, inDeadZone: false)
    case .distance:
      let value = lerp(sweepRange, t)
      return SonificationTarget(errorX: 0, errorY: 0, distanceError: value, inDeadZone: false)
    case .gazeYaw:
      let value = lerp(gazeTrimSweepRangeDegrees, t)
      return SonificationTarget(
        errorX: 0, errorY: 0, distanceError: 0, inDeadZone: true,
        gazeTrimActive: true, yawDeviationDegrees: value, pitchDeviationDegrees: 0)
    case .gazePitch:
      let value = lerp(gazeTrimSweepRangeDegrees, t)
      return SonificationTarget(
        errorX: 0, errorY: 0, distanceError: 0, inDeadZone: true,
        gazeTrimActive: true, yawDeviationDegrees: 0, pitchDeviationDegrees: value)
    }
  }

  private static func markerLabel(axis: AuditionAxis, t: Float) -> String {
    switch axis {
    case .x, .y, .distance:
      return String(format: "%+.2f", lerp(sweepRange, t))
    case .gazeYaw, .gazePitch:
      return String(format: "%+.1f°", lerp(gazeTrimSweepRangeDegrees, t))
    }
  }

  private static func lerp(_ range: ClosedRange<Float>, _ t: Float) -> Float {
    range.lowerBound + (range.upperBound - range.lowerBound) * t
  }

  /// Which named third of the distance sweep range (§6.2 round 4)
  /// a given `distanceError` sample falls in, for the `--axis distance`
  /// sweep's printed/spoken progress markers.
  enum DistanceMarker: Equatable {
    case tooFar
    case correct
    case tooClose

    init(distanceError: Float, range: ClosedRange<Float>) {
      let third = (range.upperBound - range.lowerBound) / 3
      if distanceError < range.lowerBound + third {
        self = .tooFar
      } else if distanceError > range.upperBound - third {
        self = .tooClose
      } else {
        self = .correct
      }
    }

    var text: String {
      switch self {
      case .tooFar: return "Too far"
      case .correct: return "Correct distance"
      case .tooClose: return "Too close"
      }
    }
  }

  /// Header line printed once before a sweep starts — axis-appropriate
  /// units (normalized error for `x`/`y`, degrees for the gaze-trim axes).
  static func sweepHeader(axis: AuditionAxis, seconds: Double) -> String {
    switch axis {
    case .x, .y, .distance:
      return "Sweeping \(axis.label) error from \(sweepRange.lowerBound) to "
        + "\(sweepRange.upperBound) over \(seconds)s…"
    case .gazeYaw, .gazePitch:
      return "Sweeping \(axis.label) deviation from \(gazeTrimSweepRangeDegrees.lowerBound)° to "
        + "\(gazeTrimSweepRangeDegrees.upperBound)° over \(seconds)s…"
    }
  }

  /// Starts a real-time `AudioRenderer` for `config.audio`, or prints a
  /// clear error and throws `ExitCode.failure` (task brief: "degrade with a
  /// clear error when none"). Shared by all three subcommands so the
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
