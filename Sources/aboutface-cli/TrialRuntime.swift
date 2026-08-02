import AboutFaceCore
import Dispatch
import Foundation

/// Single-consumer-per-phase distribution of `AnalysisEngine`'s output
/// stream for `trial`: one background task pumps `engine.stream(from:)`
/// continuously for the whole command run (camera capture never stops
/// between trials), and this actor fans that out to whichever phase of the
/// protocol needs frames right now.
///
/// Two things read frames at different points in the protocol: the
/// "waiting for Return, checking displacement" phase just wants the
/// latest snapshot on demand (`latest`), while the "live convergence"
/// phase needs every frame in order, so it gets its own `AsyncStream` for
/// the duration of `beginLive()...endLive()`. Only one live stream is ever
/// open at a time (one trial's live phase at a time) — `trial`'s own
/// control flow guarantees that, not this type.
///
/// One live sample: an `EngineOutput` paired with the exact `CapturedFrame`
/// it was computed from, when `--snapshots` is active (`nil` otherwise —
/// see `TrialHub.publish(_:frame:)`). Pairing them atomically at publish
/// time (rather than having a snapshot moment separately query "the latest
/// frame") means a snapshot taken when SETTLED/timeout fires always matches
/// the frame that produced the triggering `EngineOutput`, with no race
/// against a newer frame arriving in between.
struct TrialSample: Sendable {
  let output: EngineOutput
  let frame: CapturedFrame?
}

actor TrialHub {
  private(set) var latest: EngineOutput?
  /// Most recent camera frame — retained only when `--snapshots` is active,
  /// since only then does the frame pump call `publish(_:frame:)` with a
  /// non-nil `frame` (see `Trial.pumpFramesRetainingFrames` in
  /// `TrialProtocol.swift`). One buffer, overwritten every publish, never an
  /// accumulating collection; stays `nil` for the whole session without
  /// `--snapshots` — zero retained frames in that case.
  private(set) var latestFrame: CapturedFrame?
  private(set) var sourceEnded = false
  private var liveContinuation: AsyncStream<TrialSample>.Continuation?

  func publish(_ output: EngineOutput, frame: CapturedFrame? = nil) {
    latest = output
    if let frame {
      latestFrame = frame
    }
    liveContinuation?.yield(TrialSample(output: output, frame: frame))
  }

  /// The capture source's frame stream ended (camera stopped/failed).
  /// Finishes any open live stream so a `for await` loop reading it
  /// returns instead of hanging forever waiting for a frame that will
  /// never arrive.
  func markSourceEnded() {
    sourceEnded = true
    liveContinuation?.finish()
    liveContinuation = nil
  }

  /// Opens the live phase: every subsequent `publish(_:)` call also yields
  /// into the returned stream until `endLive()` is called.
  func beginLive() -> AsyncStream<TrialSample> {
    let (stream, continuation) = AsyncStream<TrialSample>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    liveContinuation = continuation
    return stream
  }

  func endLive() {
    liveContinuation?.finish()
    liveContinuation = nil
  }
}

/// Bridges blocking `readLine()` into async code without tying up a
/// cooperative-thread-pool thread for the whole wait — important here
/// specifically because, unlike `record-corpus` (which never reads stdin
/// while a camera stream is active), `trial` needs `readLine()` and the
/// `TrialHub` frame-pump task running at the same time (waiting for Return
/// while still able to answer "what's the current displacement").
/// Dispatches the blocking call onto a background queue and resumes a
/// continuation with the result, the same pattern `Speech.speak(_:)`
/// (`CorpusSpeech.swift`) uses to bridge a delegate callback into `async`.
enum StdinInput {
  static func readLineAsync() async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: readLine())
      }
    }
  }
}

/// `ContinuousClock.Duration` → fractional seconds, floored away from
/// exact 0 — the same conversion `Live.seconds(_:)` (`LiveCommand.swift`)
/// uses, duplicated here (rather than made shared) since that one is
/// `private` to `Live` and this file's copy is trivial enough that sharing
/// it isn't worth a new cross-file surface for two call sites.
enum ClockMath {
  static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

/// Prints and speaks `text` — the "every prompt and result must be
/// speech-first... spoken AND printed" rule from the task brief, applied
/// uniformly at one call site rather than duplicated at each announcement.
/// Free function (not a `Trial` method) so `TrialSelfTest.swift` and any
/// future non-`Trial` caller can use it without needing a `Trial` instance.
func announce(_ text: String, speech: Speech) async {
  print(text)
  await speech.speak(text)
}

/// Tracks the task brief's "if face absent > 5s the trial pauses with a
/// spoken notice" rule across a live convergence loop. Kept separate from
/// `TrialMetrics.swift`'s pure types since it consumes real
/// `ContinuousClock.Instant`s (there is no meaningful "hand-computed"
/// version of a wall-clock-driven pause), but is still a small, isolated
/// state machine — pulled out of `runLiveConvergence` purely to keep that
/// function's body/complexity within SwiftLint's default limits.
struct FaceLossPauseTracker {
  let pauseThresholdSeconds: Double

  private(set) var isPaused = false
  private(set) var pausedDurationSeconds: Double = 0
  private var faceLostSince: ContinuousClock.Instant?
  private var pauseStartedAt: ContinuousClock.Instant?

  enum Event { case paused, resumed }

  /// Explicit initializer: the compiler-synthesized memberwise init would
  /// be `private` (its narrowest-access rule sees the `private(set)`
  /// properties' private setters), which would make this type
  /// unconstructible from `TrialProtocol.swift`.
  init(pauseThresholdSeconds: Double) {
    self.pauseThresholdSeconds = pauseThresholdSeconds
  }

  /// Call once per live frame with whether a face was detected this frame.
  /// Returns `.paused`/`.resumed` exactly on the frame each transition
  /// happens (for the caller to announce), `nil` otherwise.
  mutating func update(hasFace: Bool, now: ContinuousClock.Instant) -> Event? {
    if hasFace {
      faceLostSince = nil
      guard isPaused, let pauseStartedAt else { return nil }
      pausedDurationSeconds += ClockMath.seconds(now - pauseStartedAt)
      isPaused = false
      self.pauseStartedAt = nil
      return .resumed
    }

    if faceLostSince == nil {
      faceLostSince = now
    }
    guard !isPaused, let faceLostSince,
      ClockMath.seconds(now - faceLostSince) >= pauseThresholdSeconds
    else {
      return nil
    }
    isPaused = true
    pauseStartedAt = now
    return .paused
  }
}

/// Everything one trial (and the loop that runs many of them) needs to
/// read but never mutate — bundled into one value, rather than five+
/// separate parameters threaded through every function in
/// `TrialProtocol.swift`, per SwiftLint's `function_parameter_count`
/// default limit. `Sendable` since every stored property already is
/// (`TrialHub` is an actor, `AudioCLISupport.FeedbackChain` is `Sendable`
/// by its own declaration, `Speech` is `@unchecked Sendable`, the rest are
/// plain value types), even though nothing here currently crosses a task
/// boundary that would require it.
struct TrialContext: Sendable {
  let hub: TrialHub
  let chain: AudioCLISupport.FeedbackChain
  let speech: Speech
  let displacementThreshold: Float
  let deadZone: Config.DeadZone
  /// `nil` without `--snapshots`; see `TrialSnapshots.swift`.
  let snapshotWriter: TrialSnapshotWriter?
}

/// Camera source construction shared by `Trial`'s real run — pulled out to
/// its own file only so `TrialCommand.swift` stays focused on argument
/// parsing and top-level orchestration. Mirrors `Live.makeSource()` /
/// `RecordCorpus.makeSource()`.
enum TrialCameraSource {
  static func make(device: String?, width: Int, height: Int, fps: Double) -> CameraCaptureSource? {
    if let device {
      return CameraCaptureSource(
        deviceUniqueID: device, width: width, height: height, frameRate: fps)
    }
    return CameraCaptureSource.defaultDevice(width: width, height: height, frameRate: fps)
  }
}
