import AVFoundation
import Synchronization

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Plain-old-data snapshot of `SonificationTarget`, published through
/// `TripleBuffer`. A `nil` `SonificationTarget` (per the contract: "nil = no
/// face, stop positional tones") becomes `hasTarget == false`.
struct ParamSnapshot: Sendable {
  var hasTarget: Bool
  var errorX: Float
  var errorY: Float
  var distanceError: Float
  var inDeadZone: Bool
  /// Tuning round 5 gaze-trim prototype fields — see
  /// `SonificationTarget.gazeTrimActive`'s doc comment.
  var gazeTrimActive: Bool
  var yawDeviationDegrees: Float
  var pitchDeviationDegrees: Float

  static let silent = ParamSnapshot(
    hasTarget: false, errorX: 0, errorY: 0, distanceError: 0, inDeadZone: true,
    gazeTrimActive: false, yawDeviationDegrees: 0, pitchDeviationDegrees: 0)

  init(
    hasTarget: Bool, errorX: Float, errorY: Float, distanceError: Float, inDeadZone: Bool,
    gazeTrimActive: Bool, yawDeviationDegrees: Float, pitchDeviationDegrees: Float
  ) {
    self.hasTarget = hasTarget
    self.errorX = errorX
    self.errorY = errorY
    self.distanceError = distanceError
    self.inDeadZone = inDeadZone
    self.gazeTrimActive = gazeTrimActive
    self.yawDeviationDegrees = yawDeviationDegrees
    self.pitchDeviationDegrees = pitchDeviationDegrees
  }

  init(_ target: SonificationTarget?) {
    guard let target else {
      self = .silent
      return
    }
    self.init(
      hasTarget: true,
      errorX: target.errorX,
      errorY: target.errorY,
      distanceError: target.distanceError,
      inDeadZone: target.inDeadZone,
      gazeTrimActive: target.gazeTrimActive,
      yawDeviationDegrees: target.yawDeviationDegrees,
      pitchDeviationDegrees: target.pitchDeviationDegrees
    )
  }
}

/// Resolved output channel pointers for one render callback, plus whether a
/// genuine second (right) channel is present. Kept as a small value type
/// purely to break `RenderState.render`'s body into smaller pieces without
/// passing four loose parameters around.
private struct ChannelPointers {
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>
  let stereo: Bool
}

/// Owns every piece of state the real-time render callback touches. A plain
/// `final class` — deliberately **not** an `actor` or a `struct` passed by
/// value — because:
///
/// - It must be usable from CoreAudio's real-time thread, which is outside
///   Swift concurrency entirely; an `actor`'s isolation checking and
///   potential executor hop are exactly the kind of thing §3.1 rules out.
/// - Its render-thread-owned fields (oscillator phases, active earcon
///   voices, the noise PRNG seed) need to persist and mutate in place across
///   calls with reference semantics and no reallocation — a `class` gives
///   that for free.
///
/// The **only** state shared across threads is `silenced` (an `Atomic<Bool>`
/// — trivially safe, no partial-write hazard for a single word),
/// `targetBuffer` (a `TripleBuffer`, wait-free SPSC), and `events` (a
/// `RingBuffer`, wait-free SPSC). Every other property below — `voices`,
/// the phase accumulators, `currentTarget`, `noiseSeedCounter` — is written
/// and read **exclusively** from `render(frameCount:audioBufferList:)` (and
/// the private helpers it calls), which per the `AudioRenderer` doc comment
/// is only ever called from the real-time thread, so those fields need no
/// synchronization at all: there is only ever one reader/writer.
final class RenderState: @unchecked Sendable {
  let config: Config.Audio
  let silenced = Atomic<Bool>(false)

  private let targetBuffer: TripleBuffer<ParamSnapshot>
  private let events: RingBuffer

  // MARK: Render-thread-owned state (see type-level doc comment)

  private let voiceCount = 4
  private let voices: UnsafeMutablePointer<Voice>

  // Not `private`: read/written from `RenderState+Positional.swift`'s
  // extension too (a different file, so plain `internal` — Swift's
  // `private` is file-scoped — matching the precedent set by
  // `AnalysisEngine`'s stored properties, which `AnalysisEngine+Framing.swift`
  // reads the same way). Still invisible outside `AboutFaceCore` either way.
  var currentTarget = ParamSnapshot.silent

  /// Phase accumulator shared by Scheme A's pitch tone and Scheme C's
  /// current-axis tone — the two are mutually exclusive per renderer
  /// instance (`config.scheme.positional` is fixed at construction), so one
  /// field suffices.
  var positionalPhase: Double = 0
  /// §6.2 vertical-axis timbre differentiation's "darkness" ingredient: a
  /// sub-octave (`f/2`) component. Needs its own accumulator rather than
  /// deriving from `positionalPhase / 2` because halving a *wrapped* phase
  /// is discontinuous (unlike integer-multiple harmonics — see
  /// `RenderState+Positional.swift`'s `verticalTimbreMix` doc comment).
  var subOctavePhase: Double = 0
  var schemeBReferencePhase: Double = 0
  var schemeBMovingPhase: Double = 0
  var pulsePhase: Double = 0
  /// Tuning round 5 gaze-trim prototype (§6.1/§6.2-adjacent, default OFF —
  /// see `Config.AudioGazeTrim`). Own phase accumulator — the trim tone's
  /// register is disjoint from the beacon's on purpose (RenderState+
  /// GazeTrim.swift), so it cannot share `positionalPhase`.
  var gazeTrimPhase: Double = 0
  /// Onset-ramp gain, `0...1` — climbs from `0` toward `1` over
  /// `Config.AudioGazeTrim.onsetRampMs` while trim is active, and is reset
  /// to `0` the instant it isn't, so every (re)activation ramps fresh with
  /// no pop. See `RenderState+GazeTrim.swift`.
  var gazeTrimRampGain: Float = 0
  /// Scheme C state machine: `true` while resolving the horizontal axis,
  /// `false` once resolved and resolving vertical (§6.2: "Solve horizontal
  /// to completion, then vertical").
  var sequentialOnHorizontal = true
  private var noiseSeedCounter: UInt32 = 0x2545_F491

  init(config: Config.Audio) {
    self.config = config
    self.targetBuffer = TripleBuffer(initial: .silent)
    self.events = RingBuffer(capacity: 32)
    self.voices = .allocate(capacity: voiceCount)
    voices.initialize(repeating: .inactive, count: voiceCount)
  }

  deinit {
    voices.deinitialize(count: voiceCount)
    voices.deallocate()
  }

  // MARK: Writer-side entry points (actor-isolated callers only)

  func publish(_ target: SonificationTarget?) {
    targetBuffer.write(ParamSnapshot(target))
  }

  func enqueue(_ event: AudioEvent) {
    events.push(EarconKind(event).rawValue)
  }

  // MARK: Render-thread entry point

  // swift-format requires the brace on its own line after a multiline
  // signature; swiftlint's opening_brace rule disagrees. Format wins (see
  // ConfigStore.swift/SignalFormatter.swift for the same workaround).
  // swiftlint:disable opening_brace
  func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>)
  {
    // swiftlint:enable opening_brace
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let frames = Int(frameCount)
    guard let channels = Self.resolveChannels(bufferList) else { return }

    // §7.5: silence MUST cut within one render buffer — checked first,
    // before touching anything else, and the whole buffer is zeroed
    // unconditionally. Any in-flight earcon voices are dropped (not
    // paused) so unsilencing later starts clean rather than resuming a
    // stale utterance. The event queue is still drained so events that
    // fire while silenced don't pile up and all burst out the instant
    // silence is lifted.
    if silenced.load(ordering: .relaxed) {
      fillSilence(channels, frames: frames)
      return
    }

    if let latest = targetBuffer.readIfNew() { currentTarget = latest }
    drainEvents()

    let sampleRate = config.engine.sampleRate
    for i in 0..<frames {
      let (left, right) = mixedSample(sampleRate: sampleRate)
      channels.left[i] = AudioSynthesis.softClip(left)
      if channels.stereo { channels.right[i] = AudioSynthesis.softClip(right) }
    }
  }

  // swiftlint:disable opening_brace
  private static func resolveChannels(_ bufferList: UnsafeMutableAudioBufferListPointer)
    -> ChannelPointers?
  {
    // swiftlint:enable opening_brace
    guard let leftRaw = bufferList[0].mData else { return nil }
    let leftPtr = leftRaw.assumingMemoryBound(to: Float.self)
    if bufferList.count > 1, let rightRaw = bufferList[1].mData {
      return ChannelPointers(
        left: leftPtr, right: rightRaw.assumingMemoryBound(to: Float.self), stereo: true)
    }
    return ChannelPointers(left: leftPtr, right: leftPtr, stereo: false)
  }

  private func fillSilence(_ channels: ChannelPointers, frames: Int) {
    for i in 0..<frames {
      channels.left[i] = 0
      if channels.stereo { channels.right[i] = 0 }
    }
    for i in 0..<voiceCount { voices[i] = .inactive }
    while events.pop() != nil {}
  }

  private func drainEvents() {
    while let raw = events.pop() {
      if let kind = EarconKind(rawValue: raw) { activateVoice(kind: kind) }
    }
  }

  /// One sample's worth of the full mix: the continuous positional tone(s)
  /// (Scheme A/C, plus Scheme B when active) plus every active earcon
  /// voice.
  ///
  /// NOTE (known limitation, not required by §13 Phase 3's acceptance
  /// list): the positional tone starts/stops at full `toneGain` instantly
  /// on the render callback where `hasTarget && !inDeadZone` flips, with no
  /// amplitude ramp. Because `positionalPhase` is not necessarily at a
  /// zero-crossing at that instant, this can produce an audible click at
  /// the dead-zone boundary in real playback. §7's dwell/hysteresis already
  /// prevents *rapid* flipping (that's the router's job upstream of
  /// `update`), so this is an occasional boundary-crossing click, not
  /// chatter — worth a short gain ramp in a follow-up once this is tuned by
  /// ear against the corpus (§16), but deliberately left out here to keep
  /// this change's scope to what requirement 1-6 actually ask for.
  private func mixedSample(sampleRate: Double) -> (Float, Float) {
    var left: Float = 0
    var right: Float = 0

    if currentTarget.hasTarget, !currentTarget.inDeadZone {
      let (posL, posR) = positionalSample(sampleRate: sampleRate)
      left += posL
      right += posR
      if let schemeB = schemeBSampleIfActive(sampleRate: sampleRate) {
        left += schemeB
        right += schemeB
      }
      // Not gaze-trim's turn — reset the onset ramp so a LATER trim
      // activation always starts from silence (see `gazeTrimRampGain`'s
      // doc comment), never resumes mid-ramp from whatever it was left at.
      gazeTrimRampGain = 0
    } else if currentTarget.hasTarget, currentTarget.gazeTrimActive {
      // Tuning round 5 (§6.1/§6.2-adjacent, default OFF): the gaze-trim
      // continuous cue takes over in place of the beacon while the
      // published target says so — mutually exclusive with the branch
      // above by construction, since `FeedbackRouter` only ever publishes
      // `gazeTrimActive: true` alongside `inDeadZone: true` (see
      // `FeedbackRouter.gazeTrimTarget(output:framing:)`).
      let (trimL, trimR) = gazeTrimSample(sampleRate: sampleRate)
      left += trimL
      right += trimR
    } else {
      gazeTrimRampGain = 0
    }

    let (voiceL, voiceR) = mixVoices(sampleRate: sampleRate)
    return (left + voiceL, right + voiceR)
  }

  /// §6.2: "Schemes A and B compose; B is a refinement layer" — Scheme B
  /// only ever layers on top of Scheme A, never Scheme C, and only inside
  /// its configured refinement zone. Returns `nil` when Scheme B shouldn't
  /// sound this sample.
  private func schemeBSampleIfActive(sampleRate: Double) -> Float? {
    guard config.scheme.schemeBEnabled, config.scheme.positional == .panPitch else { return nil }
    let magnitude = totalErrorMagnitude()
    let zoneLimit =
      Float(config.scheme.schemeBRefinementFraction) * Float(config.positional.errorRange)
    guard zoneLimit > 0, magnitude <= zoneLimit else { return nil }
    return schemeBSample(sampleRate: sampleRate, magnitude: magnitude, zoneLimit: zoneLimit)
  }

  private func mixVoices(sampleRate: Double) -> (Float, Float) {
    var left: Float = 0
    var right: Float = 0
    for v in 0..<voiceCount where voices[v].active {
      let sample = EarconVoice.sample(
        voice: &voices[v], earcons: config.earcons, heartbeat: config.heartbeat,
        sampleRate: sampleRate)
      left += sample
      right += sample
      voices[v].elapsedFrames += 1
      if voices[v].elapsedFrames >= voices[v].totalFrames {
        voices[v].active = false
      }
    }
    return (left, right)
  }

  // MARK: Earcon voices (§6.1)

  private func activateVoice(kind: EarconKind) {
    let durationMs = EarconVoice.durationMs(
      for: kind, earcons: config.earcons, heartbeat: config.heartbeat)
    let frames = EarconVoice.frameCount(
      durationMs: durationMs, sampleRate: config.engine.sampleRate)

    // Deterministic per-activation reseed (simple LCG step) so each
    // `.faceLost` noise burst sounds independent of the last, without any
    // dependency on wall-clock time or a system entropy source (both of
    // which would be a real-time-thread hazard).
    noiseSeedCounter = noiseSeedCounter &* 1_664_525 &+ 1_013_904_223

    // Prefer a free slot; if all `voiceCount` slots are busy (rare — the
    // router gates earcons with dwell/hysteresis upstream), steal whichever
    // slot has the fewest frames remaining rather than dropping the new
    // event outright.
    var target = 0
    var fewestRemaining = Int.max
    var foundFree = false
    for i in 0..<voiceCount where !foundFree {
      if !voices[i].active {
        target = i
        foundFree = true
        continue
      }
      let remaining = voices[i].totalFrames - voices[i].elapsedFrames
      if remaining < fewestRemaining {
        fewestRemaining = remaining
        target = i
      }
    }

    voices[target] = Voice(
      active: true, kind: kind, elapsedFrames: 0, totalFrames: frames,
      rngState: noiseSeedCounter | 1)
  }
}
