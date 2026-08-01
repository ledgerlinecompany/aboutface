/// The `(camera|file)` capture abstraction from spec §3.1: the single entry
/// point through which raw video frames enter the pipeline, whether from a
/// live camera (`CameraCaptureSource`) or a corpus clip on disk
/// (`FileCaptureSource`, §14).
///
/// ## Concurrency
///
/// Per §3.1, the capture queue is one of the app's four concurrency domains
/// and "must never block." No conformance may ever block the producer; the
/// right buffering policy depends on which half of `(camera|file)` a
/// conformance implements:
///
/// - **Live sources** (`CameraCaptureSource`) MUST drop stale frames when
///   the consumer falls behind — `.bufferingNewest(1)` — rather than buffer
///   unboundedly. This is a correctness requirement, not a performance
///   nicety: a backlog would mean that by the time a frame is processed it
///   no longer reflects what the camera currently sees. Live analysis wants
///   the freshest frame, not a queue of history.
/// - **Replay sources** (`FileCaptureSource`) MUST be lossless and
///   deterministic — `.unbounded`, in practice bounded by clip length. The
///   corpus (§14) exists to feed *identical* input to the pipeline on every
///   run; a dropping policy would make the delivered frame sequence depend
///   on consumer scheduling, which is exactly the noise corpus replay is
///   meant to eliminate.
///
/// ## Mirror state
///
/// Per §3.4, `mirrorState` is fixed once, at configuration time, and every
/// frame a `CaptureSource` delivers MUST be stamped with that same value — a
/// conformance never changes its mirror convention mid-stream. Downstream
/// code (the backend → `FaceGeometry` boundary, per §3.4) treats
/// `CapturedFrame.mirrorState` as the sole source of truth and never infers
/// mirroring from context.
public protocol CaptureSource: Sendable {
  /// Fixed at configuration time (§3.4). Every frame in `frames` carries
  /// this exact value in `CapturedFrame.mirrorState`.
  var mirrorState: MirrorState { get }

  /// The stream of captured frames. A single `AsyncStream` instance backs
  /// this property for the lifetime of the source — conformances create it
  /// once, in `init`, rather than regenerating it per access — so multiple
  /// callers observing `frames` share one underlying stream.
  ///
  /// Buffering policy MUST never block the producer: live sources drop
  /// stale frames, replay sources buffer losslessly; see the type-level
  /// documentation.
  var frames: AsyncStream<CapturedFrame> { get }

  /// Starts producing frames onto `frames`. Idempotent: calling `start()`
  /// while already running must not restart or duplicate delivery.
  func start() async throws

  /// Stops producing frames and finishes `frames` — iterating consumers
  /// observe stream completion, with no further elements yielded.
  /// Idempotent.
  func stop() async
}
