/// The §6.4 haptics seam: "`FeedbackRouter` treats haptics as a subscriber
/// to discrete events only — never a renderer of the continuous error
/// vector."
///
/// ## Partition rationale
///
/// `FeedbackRouter` emits two categorically different things per frame: a
/// continuous `SonificationTarget` (real-time positional error, ~30/5Hz) and
/// discrete `AudioEvent`s (entered good zone, face lost, heartbeat, ...).
/// `AudioRendering` (see `AudioContractTypes.swift`) consumes BOTH — it is
/// the primary, always-present renderer, wired directly into
/// `FeedbackRouter`'s `audio` property, not through this protocol.
/// `EventSubscriber` exists for everything else that only ever wants the
/// discrete stream: per §6.4, a future haptics module (Apple Watch via
/// `WatchConnectivity` — the phone/Mac itself isn't held in the hand, so
/// device haptics are "dead weight") registers via
/// `FeedbackRouter.addEventSubscriber(_:)` and is handed every `AudioEvent`
/// `FeedbackRouter` fires, with NO path to the continuous vector at all —
/// not "a haptics implementation that happens not to read the vector," but
/// a type that structurally cannot receive it, because its only input is
/// this protocol.
///
/// Kept intentionally to one method: anything richer (event metadata,
/// priorities, cancellation) is a haptics-module design decision for
/// whoever builds it, not something to guess at here.
public protocol EventSubscriber: Sendable {
  func handle(_ event: AudioEvent) async
}
