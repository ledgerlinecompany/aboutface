/// Sorts a session's unconsumed events into the expected-and-counted
/// categories and the genuinely unexplained remainder. Split out of
/// `AcceptanceEvaluator.swift` for SwiftLint's `file_length` budget, which CI
/// enforces as an error; this is still that type's own implementation.
///
/// Everything moved out of `unexplained` here is moved because a real session
/// produces it routinely and in volume. The maintainer's 30-minute acceptance
/// run left 52 entries in that list, of which all but a couple were
/// heartbeats, ordinary re-settle chimes, or the boundaries of blink-length
/// face-lost episodes. §13's "and nothing else" clause is only checkable if
/// the list is short enough that a human actually reads it.
///
/// Nothing is DISCARDED: every category is still reported and counted, and
/// `strayRendererActivityDuringStop` is computed by the caller from the FULL
/// unconsumed set, so anything landing inside the STOP window is still caught
/// no matter which bucket it would otherwise fall into.
extension AcceptanceEvaluator {
  /// A struct rather than the 3-tuple this started as — SwiftLint caps tuples
  /// at 2 members, and named fields read better at the call site anyway.
  struct Classification {
    let heartbeats: [AcceptanceEvent]
    let goodZoneEntries: [AcceptanceEvent]
    let unexplained: [AcceptanceEvent]

    init(
      unconsumed: [AcceptanceEvent],
      window: (startMs: Int?, endMs: Int?),
      nonEscalatingEpisodes: [AcceptanceEpisode]
    ) {
      // The boundary events of episodes that never escalated: their own
      // faceLost/faceReacquired pair, which the ladder correctly ignored and
      // which are already reported as `AcceptanceEpisode`s.
      var episodeBoundaryMs = Set<Int>()
      for episode in nonEscalatingEpisodes {
        episodeBoundaryMs.insert(episode.startMs)
        if let endMs = episode.endMs { episodeBoundaryMs.insert(endMs) }
      }

      var heartbeats: [AcceptanceEvent] = []
      var goodZoneEntries: [AcceptanceEvent] = []
      var unexplained: [AcceptanceEvent] = []

      // swift-format puts the brace of a wrapped multi-line condition on its
      // own line; swiftlint's opening_brace rule disagrees. Format wins (house
      // rule -- see FeedbackRouter.swift for the same disagreement).
      // swiftlint:disable opening_brace
      for event in unconsumed {
        if AcceptanceEvaluator.isRoutineHeartbeat(
          event, episodeStartMs: window.startMs, episodeEndMs: window.endMs)
        {
          heartbeats.append(event)
        } else if AcceptanceEvaluator.isRoutineGoodZoneEntry(
          event, episodeStartMs: window.startMs, episodeEndMs: window.endMs)
        {
          goodZoneEntries.append(event)
        } else if AcceptanceEvaluator.isNonEscalatingEpisodeBoundary(
          event, boundaryMs: episodeBoundaryMs)
        {
          continue
        } else {
          unexplained.append(event)
        }
      }
      // swiftlint:enable opening_brace
      self.heartbeats = heartbeats
      self.goodZoneEntries = goodZoneEntries
      self.unexplained = unexplained
    }
  }

  /// An arrival chime OUTSIDE the escalated episode: the user re-settling,
  /// which a long session does repeatedly and legitimately. One INSIDE the
  /// episode stays evidence, on the same reasoning as `isRoutineHeartbeat` —
  /// arriving in the good zone while the face is lost is a contradiction.
  static func isRoutineGoodZoneEntry(
    _ event: AcceptanceEvent, episodeStartMs: Int?, episodeEndMs: Int?
  ) -> Bool {
    guard event.kind == .audioEvent(.enteredGoodZone) else { return false }
    guard let episodeStartMs else { return true }
    if event.elapsedMs < episodeStartMs { return true }
    guard let episodeEndMs else { return false }
    return event.elapsedMs > episodeEndMs
  }

  /// The `faceLost`/`faceReacquired` pair of an episode that never escalated
  /// — already reported as an `AcceptanceEpisode`, so repeating each as a
  /// loose event would double-count it.
  static func isNonEscalatingEpisodeBoundary(
    _ event: AcceptanceEvent, boundaryMs: Set<Int>
  ) -> Bool {
    switch event.kind {
    case .audioEvent(.faceLost), .audioEvent(.faceReacquired):
      return boundaryMs.contains(event.elapsedMs)
    default:
      return false
    }
  }

  /// `assembleReport`'s inputs, bundled — SwiftLint caps parameter count at
  /// 5 and CI enforces it as an error. Same precedent as
  /// `CameraFormatProbe.CaptureRequest`.
  struct ReportInputs {
    let rungs: [AcceptanceReport.RungResult]
    let unconsumed: [AcceptanceEvent]
    let episodes: [AcceptanceEpisode]
    let escalatedCount: Int
    let windowStartMs: Int?
    let windowEndMs: Int?
    let stopMs: Int?
    let reference: ReferenceStart
  }

  static func assembleReport(_ inputs: ReportInputs) -> AcceptanceReport {
    let rungs = inputs.rungs
    let unconsumed = inputs.unconsumed
    let episodes = inputs.episodes
    let escalatedCount = inputs.escalatedCount
    let windowStartMs = inputs.windowStartMs
    let windowEndMs = inputs.windowEndMs
    let stopMs = inputs.stopMs
    let reference = inputs.reference
    let nonEscalating = episodes.filter { !$0.escalated }
    let classified = Classification(
      unconsumed: unconsumed, window: (startMs: windowStartMs, endMs: windowEndMs),
      nonEscalatingEpisodes: nonEscalating)
    // Computed from the FULL unconsumed set, never the bucketed remainder:
    // §7.3's silence is the safety-critical claim, so a heartbeat or chime
    // inside the STOP window must still be caught no matter which category it
    // would otherwise land in.
    let strayDuringStop = Self.strayRendererActivity(
      unexplained: unconsumed, stopElapsedMs: stopMs, recoveryElapsedMs: windowEndMs)
    return AcceptanceReport(
      rungs: rungs,
      unexplainedEvents: classified.unexplained,
      heartbeats: classified.heartbeats,
      nonEscalatingEpisodes: nonEscalating,
      escalatedEpisodeCount: escalatedCount,
      routineGoodZoneEntries: classified.goodZoneEntries,
      strayRendererActivityDuringStop: strayDuringStop,
      referenceEpisodeStartMs: reference.startMs,
      referenceEpisodeStartIsInferred: reference.isInferred)
  }

}
