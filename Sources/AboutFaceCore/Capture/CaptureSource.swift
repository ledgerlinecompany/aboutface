/// The `(camera|file)` capture abstraction from spec §3.1: the single entry
/// point through which raw video frames enter the pipeline, whether from a
/// live camera (`CameraCaptureSource`) or a corpus clip on disk
/// (`FileCaptureSource`, §14).
///
/// ## Concurrency
///
/// Per §3.1, the capture queue is one of the app's four concurrency domains
/// and "must never block." Conformances MUST back `frames` with an
/// `AsyncStream` configured with a buffering policy that drops stale
/// elements when the consumer falls behind — `.bufferingNewest(1)` — rather
/// than the default unbounded buffer. This is a correctness requirement, not
/// a performance nicety: an unbounded buffer would let a slow analysis actor
/// build an ever-growing backlog, so that by the time a frame is finally
/// processed it no longer reflects what the camera currently sees. Analysis
/// wants the freshest frame, not a queue of history.
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
  /// Buffering policy MUST drop stale frames rather than block the producer
  /// or grow unboundedly; see the type-level documentation.
  var frames: AsyncStream<CapturedFrame> { get }

  /// Starts producing frames onto `frames`. Idempotent: calling `start()`
  /// while already running must not restart or duplicate delivery.
  func start() async throws

  /// Stops producing frames and finishes `frames` — iterating consumers
  /// observe stream completion, with no further elements yielded.
  /// Idempotent.
  func stop() async
}
