/// Phase 4.5's **status pulse** (`docs/design/phase-4.5-app-design.md` §3.3.1)
/// — the single periodic signal that runs for the whole time the app is
/// watching, and the only sound a near-silent monitoring session normally
/// produces.
///
/// ## What changed, and why it is a correction rather than a feature
///
/// §6.1's liveness heartbeat has always been scheduled from INSIDE a confirmed
/// good zone: `tickGoodZone` sets `nextHeartbeatAt`, and leaving the good zone
/// clears it (`onConfirmedStateChanged`). The consequence, in monitoring, is
/// that drifting out of frame makes the app go SILENT exactly when something
/// is wrong — §6.1's own silence-ambiguity failure, inverted. The user cannot
/// tell "I have drifted" from "it died."
///
/// The pulse fixes that by running whenever a face is being tracked, in or out
/// of the zone. It is the same sound at the same cadence; what changes is that
/// it no longer stops at the moment it is most needed.
///
/// ## Scope of this file
///
/// Monitoring only. Converging (§5.1 Setup) keeps its existing behavior
/// unchanged — there the positional beacon is the continuous signal, and the
/// heartbeat's good-zone-only scheduling is exactly right, because it marks
/// "you are placed and I am still here" against a background of active
/// guidance. Splitting the two is deliberate: the two phases have different
/// jobs (design doc §3), so they get different ambient behavior.
///
/// ## What the pulse yields to
///
/// - **§7.3's face-lost ladder.** No face means the ladder owns the
///   soundscape: its own earcon, its spoken rung, and then total silence at
///   the 30s STOP. A pulse continuing underneath would both muddle the ladder
///   and defeat the STOP's whole purpose.
/// - **`userLikelyAway`.** Guaranteed by `fire`'s own blanket guard rather
///   than re-checked here, so there is one place that decision lives.
/// - **§7.5 manual silence.** Same — `fire` enforces it.
///
/// ## Not yet carrying a bit
///
/// The design has this pulse carrying one bit of state ("is everything okay —
/// if not, ask me") by changing TIMBRE while keeping cadence. That needs a
/// second earcon and the maintainer's ear, and it needs the
/// partially-out-of-frame geometry §7.4's `.partiallyOutOfFrame` stub still
/// lacks. Both are the next PR. This one establishes the continuous pulse the
/// bit will ride on, and is a strict improvement on its own.
extension FeedbackRouter {
  /// Fires the monitoring pulse on `heartbeatIntervalMs` cadence for as long
  /// as a face is being tracked. Called every frame from `tickAnnouncements`,
  /// after the per-state work, so a state transition on this frame has already
  /// been handled before the ambient signal is considered.
  func tickMonitorPulse(output: EngineOutput, at time: ContinuousClock.Instant) async {
    guard mode == .monitor else { return }

    // No face: §7.3's ladder owns this. Clearing the schedule (rather than
    // merely skipping) is what makes the pulse resume on a fresh cadence when
    // the face returns, instead of immediately firing a pulse that was "due"
    // during an absence nobody was present for.
    guard output.analysis.signalState != .noFace, output.analysis.signalState != .noSignal else {
      nextHeartbeatAt = nil
      // The cropped/not-cropped question is meaningless with no face to ask it
      // about, and a user who walks back may be perfectly placed — greeting
      // them with a stale warning would be a lie the pulse cannot explain.
      pulseMachine?.reset()
      return
    }

    let pulseState = advancePulseState(output: output, at: time)

    guard let due = nextHeartbeatAt else {
      // First tracked frame of this monitoring stretch: start the cadence.
      // Deliberately does NOT fire immediately — the user has just been told
      // something (the arrival earcon, or a recovery) and an instant pulse on
      // top of it would read as part of that event rather than as the start of
      // ambient watching.
      nextHeartbeatAt = time.advanced(by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
      return
    }

    guard time >= due else { return }
    nextHeartbeatAt = due.advanced(by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
    // §6.1: "The heartbeat is not optional." Exempt from §5.2's rate limit for
    // the same reason it always has been — it is the mechanism that makes
    // "good" distinguishable from "the app crashed," not discretionary
    // chatter for that budget to ration.
    let event: AudioEvent = pulseState == .attention ? .attentionPulse : .livenessHeartbeat
    await fire(event: event, phrase: nil, key: nil, at: time, bypassRateLimit: true)
  }

  /// Feeds this frame's cropped/not-cropped reading to the pulse's state
  /// machine and returns the state to sound. Runs on EVERY tracked frame, not
  /// only on the ones that fire a pulse: the machine's dwells are measured in
  /// seconds of held condition, so it needs the whole stream, not the samples
  /// that happen to land on the cadence.
  private func advancePulseState(
    output: EngineOutput, at time: ContinuousClock.Instant
  ) -> PulseStateMachine.State {
    let origin = pulseClockOrigin ?? time
    if pulseClockOrigin == nil { pulseClockOrigin = origin }
    if pulseMachine == nil {
      pulseMachine = PulseStateMachine(
        enterMs: feedbackConfig.outOfFrameEnterMs, exitMs: feedbackConfig.outOfFrameExitMs)
    }

    let isCropped =
      output.analysis.primary.map {
        FrameEdgeCrop.isCropped(
          boundingBox: $0.boundingBox,
          margin: feedbackConfig.frameEdgeCropMargin,
          flagsTopEdge: feedbackConfig.frameEdgeCropFlagsTopEdge)
      } ?? false

    let seconds = Self.milliseconds(from: origin, to: time)
    return pulseMachine?.update(isCropped: isCropped, now: Double(seconds) / 1000) ?? .normal
  }
}
