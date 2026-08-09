#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// One-shot discrete-event sound kinds, matching `AudioEvent` 1:1. A
/// separate type (rather than reusing `AudioEvent` directly) so the
/// render-thread voice machinery only ever deals with a trivial,
/// `RawRepresentable`-as-`UInt8` value that can travel through
/// `RingBuffer` (§3.1: no Swift enum-with-payload marshaling on the render
/// thread, just a byte).
enum EarconKind: UInt8 {
  case enteredGoodZone = 0
  case livenessHeartbeat = 1
  case faceLost = 2
  case lowConfidence = 3
  case noSignal = 4
  case faceReacquired = 5
  case attentionPulse = 6

  init(_ event: AudioEvent) {
    switch event {
    case .enteredGoodZone: self = .enteredGoodZone
    case .livenessHeartbeat: self = .livenessHeartbeat
    case .faceLost: self = .faceLost
    case .lowConfidence: self = .lowConfidence
    case .noSignal: self = .noSignal
    case .faceReacquired: self = .faceReacquired
    case .attentionPulse: self = .attentionPulse
    }
  }
}

/// One active earcon playback slot. Plain-old-data (no reference types, no
/// `Optional` of a reference type) so a fixed array of these can live as
/// render-thread-owned state with no allocation once `RenderState` sets it
/// up — see that type's `voices` property.
///
/// Every earcon is synthesized as a pure function of `elapsedFrames` (via
/// `EarconVoice.sample`), not by accumulating a running oscillator phase
/// sample-to-sample. This is deliberate: `sin(2·pi·f·t)` for a fixed `f`, or
/// the closed-form chirp phase for a linear sweep (see `EarconVoice.sample`
/// for the derivation), are just as continuous and click-free as phase
/// accumulation, but need no persistent phase field at all — one less piece
/// of mutable state to get wrong on the render thread.
struct Voice {
  var active: Bool = false
  var kind: EarconKind = .enteredGoodZone
  var elapsedFrames: Int = 0
  var totalFrames: Int = 0
  /// xorshift32 state, seeded fresh at activation (see
  /// `RenderState.activateVoice`) — used only by `.faceLost`'s noise burst.
  var rngState: UInt32 = 1

  static let inactive = Voice()
}

enum EarconVoice {
  /// Smooth "hump" envelope: 0 at `t == 0`, peak at the midpoint, 0 at
  /// `t == duration`. Guarantees every earcon starts and ends at exactly
  /// zero amplitude — no separate attack/decay bookkeeping needed, and no
  /// possibility of a click at a voice's activation or deactivation
  /// boundary regardless of what the carrier waveform is doing at that
  /// instant.
  /// Phase 4.5's attention pulse: a DOUBLE TAP slightly below the heartbeat's
  /// pitch. Two cues carry the same one bit — rhythm and pitch — because
  /// redundant coding survives a laptop speaker and a talking colleague better
  /// than either alone, and this sound has to stay distinguishable from the
  /// heartbeat after an hour of habituation.
  private static func attentionPulse(_ pulse: AudioAttentionPulse, t: Double) -> Float {
    let noteSeconds = pulse.noteDurationMs / 1000
    let gapSeconds = pulse.gapMs / 1000
    if t < noteSeconds {
      return tap(pulse: pulse, localT: t, noteSeconds: noteSeconds)
    }
    let secondStart = noteSeconds + gapSeconds
    if t >= secondStart {
      return tap(pulse: pulse, localT: t - secondStart, noteSeconds: noteSeconds)
    }
    return 0
  }

  /// One percussive tap: fast attack, exponential decay, harmonically driven.
  ///
  /// Deliberately does NOT use the shared `envelope(t:duration:)` window every
  /// other earcon uses. That window is symmetric, so a 55ms tap fades in over
  /// ~27ms — fine for a single sustained cue, fatal for a PAIR, because a
  /// listener counts onsets rather than tones and a fade-in offers no onset to
  /// count (maintainer, 2026-08-07: "it's a little soft for an onset to tell
  /// it's a double").
  ///
  /// Drive is the second half of the same problem: an onset is audible in
  /// proportion to its high-frequency content, so a pure sine's transient is
  /// nearly inaudible however fast the attack. `tanh` waveshaping, gain-
  /// normalized exactly as `RenderState+VerticalTimbre.overdriveComponent`
  /// does it, puts energy where the ear locates attacks. `drive == 0` is an
  /// exact identity pass, so the pure-sine version stays reachable by config.
  private static func tap(
    pulse: AudioAttentionPulse, localT: Double, noteSeconds: Double
  ) -> Float {
    guard localT >= 0, localT < noteSeconds, noteSeconds > 0 else { return 0 }
    let attackSeconds = max(0, min(pulse.attackMs / 1000, noteSeconds))
    let amplitude: Double
    if attackSeconds > 0, localT < attackSeconds {
      amplitude = localT / attackSeconds
    } else {
      let decaySpan = max(noteSeconds - attackSeconds, .leastNonzeroMagnitude)
      let progress = (localT - attackSeconds) / decaySpan
      amplitude = exp(-max(0, pulse.decayCurve) * progress)
    }

    let carrier = sin(2 * .pi * pulse.freqHz * localT)
    let drive = max(0, min(1, pulse.drive))
    let shaped: Double
    if drive <= 0 {
      shaped = carrier
    } else {
      let driveGain = 1 + drive * 6
      shaped = carrier + drive * (tanh(driveGain * carrier) / tanh(driveGain) - carrier)
    }
    return Float(amplitude * shaped * pulse.gain)
  }

  private static func envelope(t: Double, duration: Double) -> Double {
    guard duration > 0, t >= 0, t <= duration else { return 0 }
    return sin(.pi * t / duration)
  }

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  /// Closed-form phase for a linear frequency sweep from `startHz` to
  /// `endHz` over `duration` seconds, evaluated at time `t`. A linear sweep
  /// has instantaneous frequency `f(t) = f0 + (f1-f0)·t/T`; phase is the
  /// integral of `2·pi·f(t)` from `0` to `t`, which has the closed form
  /// below. Using the closed form (rather than accumulating phase
  /// sample-by-sample) means the sweep is a pure function of elapsed time,
  /// matching the rest of this type's no-persistent-phase design.
  private static func sweepPhase(t: Double, startHz: Double, endHz: Double, duration: Double)
    -> Double
  {
    // swiftlint:enable opening_brace
    guard duration > 0 else { return 0 }
    let k = endHz - startHz
    return 2 * .pi * (startHz * t + k * t * t / (2 * duration))
  }

  /// Frame count for a duration in milliseconds, at `sampleRate`. Rounds up
  /// so a very short configured duration never activates a zero-frame (i.e.
  /// permanently-inaudible) voice.
  static func frameCount(durationMs: Double, sampleRate: Double) -> Int {
    max(1, Int((durationMs / 1000 * sampleRate).rounded(.up)))
  }

  /// Total sounding duration (ms) for one activation of `kind`, given
  /// `earcons`/`heartbeat` config. Single source of truth for "how long
  /// does this earcon last" — used both by `RenderState.activateVoice` (to
  /// size the voice's `totalFrames`) and by tests (to know how many frames
  /// to render before asserting the voice has finished).
  static func durationMs(
    for kind: EarconKind, earcons: Config.AudioEarcons, heartbeat: Config.AudioHeartbeat
  ) -> Double {
    switch kind {
    case .enteredGoodZone:
      let c = earcons.enteredGoodZone
      return 2 * c.noteDurationMs + c.gapMs
    case .livenessHeartbeat:
      return heartbeat.durationMs
    case .attentionPulse:
      let pulse = heartbeat.attention
      return pulse.noteDurationMs * 2 + pulse.gapMs
    case .faceLost:
      return earcons.faceLost.durationMs
    case .lowConfidence:
      return earcons.lowConfidence.durationMs
    case .noSignal:
      return earcons.noSignal.durationMs
    case .faceReacquired:
      return earcons.faceReacquired.durationMs
    }
  }

  /// Renders one sample of `voice`'s current earcon, given its elapsed
  /// frame count. `voice` is `inout` only because `.faceLost`'s noise burst
  /// advances `rngState` each sample; every other kind reads `voice` without
  /// mutating it.
  static func sample(
    voice: inout Voice, earcons: Config.AudioEarcons, heartbeat: Config.AudioHeartbeat,
    sampleRate: Double
  ) -> Float {
    let t = Double(voice.elapsedFrames) / sampleRate
    let duration = Double(voice.totalFrames) / sampleRate

    switch voice.kind {
    case .enteredGoodZone:
      let c = earcons.enteredGoodZone
      let noteDuration = c.noteDurationMs / 1000
      let gap = c.gapMs / 1000
      if t < noteDuration {
        let env = envelope(t: t, duration: noteDuration)
        return Float(env * sin(2 * .pi * c.note1Hz * t)) * Float(c.gain)
      } else if t < noteDuration + gap {
        return 0
      } else if t < 2 * noteDuration + gap {
        let localT = t - (noteDuration + gap)
        let env = envelope(t: localT, duration: noteDuration)
        return Float(env * sin(2 * .pi * c.note2Hz * localT)) * Float(c.gain)
      }
      return 0

    case .livenessHeartbeat:
      let env = envelope(t: t, duration: duration)
      return Float(env * sin(2 * .pi * heartbeat.freqHz * t)) * Float(heartbeat.gain)

    case .attentionPulse:
      return attentionPulse(heartbeat.attention, t: t)

    case .faceLost:
      let c = earcons.faceLost
      let env = envelope(t: t, duration: duration)
      let noise = AudioSynthesis.whiteNoiseSample(&voice.rngState)
      return Float(env) * noise * Float(c.gain)

    case .lowConfidence:
      let c = earcons.lowConfidence
      let env = envelope(t: t, duration: duration)
      let phase = sweepPhase(t: t, startHz: c.startHz, endHz: c.endHz, duration: duration)
      return Float(env * sin(phase)) * Float(c.gain)

    case .noSignal:
      let c = earcons.noSignal
      let env = envelope(t: t, duration: duration)
      let carrier = AudioSynthesis.squareWave(phase: 2 * .pi * c.freqHz * t)
      let am = 0.5 + 0.5 * sin(2 * .pi * c.modHz * t)
      return Float(env) * carrier * Float(am) * Float(c.gain)

    case .faceReacquired:
      let c = earcons.faceReacquired
      let env = envelope(t: t, duration: duration)
      let phase = sweepPhase(t: t, startHz: c.startHz, endHz: c.endHz, duration: duration)
      return Float(env * sin(phase)) * Float(c.gain)
    }
  }
}
