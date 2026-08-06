/// One face-lost episode: an `AudioEvent.faceLost` and the
/// `AudioEvent.faceReacquired` that ended it, plus whether it escalated all
/// the way to §7.3's rung-3 STOP.
public struct AcceptanceEpisode: Sendable, Equatable {
  /// Rung 1's earcon time — the first moment the episode was audible, not
  /// the moment the face was actually lost (that is unobservable; see
  /// `AcceptanceReport.referenceEpisodeStartIsInferred`).
  public let startMs: Int
  /// `nil` when the run ended before the face came back.
  public let endMs: Int?
  /// Whether a `userLikelyAway(true)` fell inside this episode. §7.3's rung 3
  /// fires no sound, so this is the ONLY marker distinguishing the deliberate
  /// absence §13's acceptance is about from an ordinary blink-length dropout.
  public let escalated: Bool

  public var durationMs: Int? { endMs.map { $0 - startMs } }

  public init(startMs: Int, endMs: Int?, escalated: Bool) {
    self.startMs = startMs
    self.endMs = endMs
    self.escalated = escalated
  }
}

/// Splits a recorded session into face-lost episodes.
///
/// ## Why this exists
///
/// `AcceptanceEvaluator` originally matched §7.3's four rungs by scanning for
/// the FIRST eligible event of each kind. That silently assumed a session
/// contains exactly one face-lost episode. The maintainer's real 30-minute
/// acceptance run (2026-08-06) contained **ten**: he leaned out of frame, he
/// looked away, he settled back into his chair. Nine were a second or two
/// long; one was the deliberate ten-minute absence the acceptance is actually
/// about.
///
/// Anchoring on the first earcon picked a two-second blip 57 seconds in, so
/// the real ladder — which fired perfectly, "No face." at +5.0s and the STOP
/// at +30.4s — was scored as "OFF SCHEDULE by +255060ms," and the single
/// recovery was scored as a duplicate because later blips also produced
/// `faceReacquired`. Three rungs read as failures on a run that passed.
///
/// An instrument that reports a false negative on a passing run is exactly as
/// useless as one that reports a false pass, and for the same reason: nobody
/// can act on its verdict. Hence segmentation — find the episode that
/// actually escalated, and judge that one.
public enum AcceptanceEpisodeSegmenter {
  /// Walks `events` in order, opening an episode at each `faceLost` and
  /// closing it at the next `faceReacquired`.
  ///
  /// A `faceLost` arriving while an episode is already open does not open a
  /// second one — `FeedbackRouter` cannot be in two face-lost episodes at
  /// once, so that shape means the recorder saw something odd, and merging is
  /// the reading that keeps the timeline honest rather than inventing a
  /// nested episode that never existed.
  public static func segment(_ events: [AcceptanceEvent]) -> [AcceptanceEpisode] {
    var episodes: [AcceptanceEpisode] = []
    var openStartMs: Int?
    var openEscalated = false

    for event in events {
      switch event.kind {
      case .audioEvent(.faceLost):
        if openStartMs == nil {
          openStartMs = event.elapsedMs
          openEscalated = false
        }
      case .audioEvent(.faceReacquired):
        guard let startMs = openStartMs else { continue }
        episodes.append(
          AcceptanceEpisode(startMs: startMs, endMs: event.elapsedMs, escalated: openEscalated))
        openStartMs = nil
        openEscalated = false
      case .userLikelyAway(true):
        // Rung 3 inside the currently open episode. A STOP with no episode
        // open is not attributed to anything — it would mean the router went
        // away without the ladder ever making a sound, which is a finding in
        // itself and stays visible in `unexplainedEvents`.
        if openStartMs != nil { openEscalated = true }
      default:
        continue
      }
    }

    // An episode still open at the end of the log is real and must not be
    // dropped: "the user never came back" is precisely the case §7.3's STOP
    // exists for, and discarding it would hide the most important episode a
    // session can contain.
    if let startMs = openStartMs {
      episodes.append(AcceptanceEpisode(startMs: startMs, endMs: nil, escalated: openEscalated))
    }
    return episodes
  }
}
