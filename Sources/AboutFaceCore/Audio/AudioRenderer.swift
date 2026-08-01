import AVFoundation
import Synchronization

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

public enum AudioRendererError: Error, Sendable, Equatable {
  case invalidFormat
  case notOfflineMode
  case offlineRenderFailed(String)
}

/// `AVAudioEngine`-backed `AudioRendering` conformance (§13 Phase 3). See
/// `RenderState` below for the real-time-safety design; this type is the
/// thin actor-isolated shell around it that owns the `AVAudioEngine`/
/// `AVAudioSourceNode` graph and satisfies the `AudioRendering` contract.
///
/// Being an `actor` serializes `update`/`play`/`setSilenced`/`start`/`stop`
/// against each other and against themselves — i.e. it guarantees a single
/// writer into `RenderState`'s cross-thread buffers, which is exactly the
/// single-producer half of the single-producer/single-consumer contract
/// `TripleBuffer`/`RingBuffer` are built on. The render callback itself
/// (`RenderState.render`) runs on CoreAudio's real-time thread, entirely
/// outside Swift concurrency — it is `nonisolated` by construction (a plain
/// closure captured once at `start()`), never hops onto the actor, and never
/// awaits anything.
public actor AudioRenderer: AudioRendering {
  /// `.offline` backs the deterministic, CI-safe tests (§13 Phase 3
  /// requirement 6) via `AVAudioEngine`'s manual rendering mode — same
  /// engine graph and same render callback as `.realtime`, just pulled by
  /// `renderOffline(frameCount:)` instead of a live output device.
  public enum RenderingMode: Sendable, Equatable {
    case realtime
    case offline
  }

  private let config: Config.Audio
  private let mode: RenderingMode
  private let engine = AVAudioEngine()
  private let renderState: RenderState
  private var sourceNode: AVAudioSourceNode?
  private var isRunning = false

  public init(config: Config.Audio = .defaults, mode: RenderingMode = .realtime) {
    self.config = config
    self.mode = mode
    self.renderState = RenderState(config: config)
  }

  public func start() async throws {
    guard !isRunning else { return }

    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: config.engine.sampleRate, channels: 2)
    else {
      throw AudioRendererError.invalidFormat
    }

    // Captured as a `let` local, not `self` — the render block must never
    // reference the actor (§3.1: no actor hop from the render thread). See
    // the type-level doc comment for why capturing `state` here is
    // real-time-safe.
    let state = renderState
    let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
      state.render(frameCount: frameCount, audioBufferList: audioBufferList)
      return noErr
    }

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    sourceNode = node

    if mode == .offline {
      let maxFrames = AVAudioFrameCount(config.engine.bufferFrameSize * 4)
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
    }

    try engine.start()
    isRunning = true
  }

  public func stop() async {
    guard isRunning else { return }
    engine.stop()
    if let node = sourceNode {
      engine.disconnectNodeOutput(node)
      engine.detach(node)
    }
    sourceNode = nil
    isRunning = false
  }

  public func update(_ target: SonificationTarget?) async {
    renderState.publish(target)
  }

  public func play(_ event: AudioEvent) async {
    renderState.enqueue(event)
  }

  public func setSilenced(_ silenced: Bool) async {
    // Relaxed is sufficient: this is a single boolean flag with no other
    // memory that needs to be ordered around it (§7.5's "one render buffer"
    // requirement is about *when* the render thread next observes the
    // flag, which is bounded by CoreAudio's callback cadence regardless of
    // memory ordering, not about publishing associated data).
    renderState.silenced.store(silenced, ordering: .relaxed)
  }

  /// Test-only offline pull, per §13 Phase 3 requirement 6 ("use
  /// AVAudioEngine's manual rendering mode for deterministic offline
  /// tests"). Exercises the exact same `AVAudioSourceNode` render block as
  /// live playback — only the pull mechanism differs — so a passing test
  /// here is evidence about the real render path, not a bypass of it.
  ///
  /// Returns plain `[Float]` channel arrays rather than the `AVAudioPCMBuffer`
  /// `engine.renderOffline` produces internally: `AVAudioPCMBuffer` is not
  /// `Sendable` (it's a mutable Objective-C buffer object), so handing one
  /// back across the actor boundary to a `nonisolated` test context would
  /// itself be a concurrency-safety hole — copying the samples into a
  /// `Sendable` value type here is the correct fix, not a workaround.
  public func renderOffline(frameCount: AVAudioFrameCount) throws -> OfflineSamples {
    guard mode == .offline else { throw AudioRendererError.notOfflineMode }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: engine.manualRenderingFormat, frameCapacity: frameCount)
    else {
      throw AudioRendererError.invalidFormat
    }
    let status = try engine.renderOffline(frameCount, to: buffer)
    guard status == .success else {
      throw AudioRendererError.offlineRenderFailed(String(describing: status))
    }
    guard let channels = buffer.floatChannelData else {
      throw AudioRendererError.invalidFormat
    }
    let frameLength = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: channels[0], count: frameLength))
    let right =
      buffer.format.channelCount > 1
      ? Array(UnsafeBufferPointer(start: channels[1], count: frameLength))
      : left
    return OfflineSamples(left: left, right: right)
  }

  /// `Sendable` copy of one `renderOffline(frameCount:)` pull's channel data.
  public struct OfflineSamples: Sendable, Equatable {
    public let left: [Float]
    public let right: [Float]
  }
}
