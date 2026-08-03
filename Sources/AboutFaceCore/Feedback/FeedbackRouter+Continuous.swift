/// §6.2's continuous positional sonification channel — the type-level doc
/// comment on `FeedbackRouter` calls this out as one of the "two
/// independent channels per frame," and this file is now the whole of it.
/// Split out of `FeedbackRouter.swift` once the §7.3 rung-3 STOP added a
/// second, comment-heavy branch (the beacon-cut guard below) to what used
/// to be a single method: keeping `updateContinuousSonification` on the
/// main type left it sitting right at SwiftLint's `file_length` ceiling,
/// and — per the maintainer's own framing — a file that lands ONE LINE
/// under the limit just means the next PR to touch `FeedbackRouter`
/// (Monitor mode plumbing) either blows it or pays the same trim-for-space
/// tax again. Splitting proactively, not compressing comments to fit, is
/// the house rule; same reasoning `FeedbackRouter+FaceLost.swift` and
/// `FeedbackRouter+GoodZoneAdvisories.swift` each give for their own
/// splits. Everything here is still `FeedbackRouter`'s own implementation.
extension FeedbackRouter {
  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter+Announcements.swift for the same
  // disagreement over multiline conditions).
  // swiftlint:disable opening_brace
  /// §6.2 continuous positional sonification. Per this round's brief:
  /// "continuous `SonificationTarget` updates while a face is tracked and
  /// out of dead zone... on entering good zone... stop positional updates."
  /// That "out of dead zone" clause is checked directly against
  /// `FramingState.inDeadZone` here — NOT gated by the announcement
  /// pipeline's N-frame/dwell machinery, so positional feedback stays
  /// real-time and resumes the instant `inDeadZone` flips back to `false`
  /// (§4's hysteresis already prevents that flip from chattering; adding a
  /// second debounce here would only add latency to a fast correction
  /// loop §1 exists to keep fast).
  ///
  /// Also requires `signalState == .ok`: `framing` can be non-`nil` even
  /// when `signalState` is `.noSignal` or `.lowConfidence` (a face was
  /// found on an otherwise near-uniform or low-confidence frame — see
  /// `makeOutput`'s test-support doc comment for the real
  /// `AnalysisEngine.process(_:)` code path that produces this), and §7.4
  /// ranks both of those ABOVE framing error in the priority ladder for
  /// exactly this reason: a positional reading taken during an unreliable
  /// signal is not trustworthy enough to sonify in real time, even though
  /// it exists. This is the continuous channel's own application of that
  /// same priority judgment — it has no ladder of its own to consult.
  ///
  /// **Tuning round 5 addition (gaze trim, default OFF):** inside the dead
  /// zone, this used to simply stop calling `audio.update` at all (the
  /// legacy "silence + heartbeat" posture — §6.1). It still does exactly
  /// that when `gazeTrimTarget(output:framing:)` returns `nil` (flag off,
  /// wrong mode, not yet confirmed good-zone, etc. — see that method's own
  /// gating), so flag-off behavior is bit-for-bit unchanged. When it
  /// returns a target, that target is published INSTEAD of halting —
  /// always with `inDeadZone: true`, which is what keeps the beacon branch
  /// above (`!currentTarget.inDeadZone` in `RenderState.mixedSample`) from
  /// also firing, so the two continuous cues are mutually exclusive by
  /// construction, never layered.
  func updateContinuousSonification(_ output: EngineOutput, at time: ContinuousClock.Instant) async
  {
    // swiftlint:enable opening_brace
    guard !isSilenced else { return }
    // §7.3 rung 3: the same blanket guard `fire` applies, and for the same
    // reason — see `userLikelyAway`'s doc comment in `FeedbackRouter.swift`.
    // It has to live here too, not just in `fire`, because this method's
    // own `signalState != .ok` branch below only guarantees `nil` for
    // frames that still look like face-lost; a stray frame where the
    // backend re-detects a face for an instant (or the user briefly
    // reappears without holding still long enough to reconfirm) would
    // otherwise slip a real `SonificationTarget` out to `audio.update`
    // while the router still believes the user is away.
    // `FeedbackRouterFaceLostEscalationTests` exercises exactly this with a
    // short, sub-N-frame burst of good-zone-shaped frames during an away
    // episode.
    //
    // This is NOT a plain early return, though — and that distinction is
    // the whole point. `ingest(_:at:)` runs `tickAnnouncements` (where
    // rung 3 sets `userLikelyAway`) BEFORE this method, so the very frame
    // that crosses the 30s STOP boundary can arrive here with a real
    // `SonificationTarget` already "playing" from `audio`'s point of view
    // (sent on some earlier frame that had `.ok` signal + framing but
    // wasn't a face-lost frame — the continuous channel is deliberately
    // NOT N-frame gated, so a single stray detection is enough to send
    // one). A guard that only stops SENDING further updates from here on
    // would leave that target droning forever at an empty desk — exactly
    // the §6.1 failure this whole method's "ALWAYS resolve to exactly one
    // of {beacon, trim, nil} and send it" design below already fixed once,
    // just reintroduced permanently instead of transiently. So: if the
    // last send was not already `nil`, this sends the CUT —
    // `audio.update(nil)` — once, on the transition frame, and only then
    // goes quiet. Sending `nil` is silence, not noise, so this one call is
    // fully consistent with rung 3's "total silence" requirement: "zero
    // renderer calls" is the bar for anything that MAKES sound, but the
    // one call that STOPS sound is required, not exempt from it.
    if userLikelyAway {
      guard !lastContinuousSendWasNil else { return }
      lastContinuousSendWasNil = true
      await audio.update(nil)
      return
    }

    // ALWAYS resolve to exactly one of {beacon target, trim target, nil}
    // and send it (nil deduped). The previous shape returned early on
    // non-ok states without ever sending nil, leaving the renderer
    // droning its last target through face-lost — §6.1's exact failure
    // ("if it can't see a face, it shouldn't emit a tone", app field
    // finding). Resolving-then-sending also cuts the beacon the instant
    // the dead zone is entered, rather than after the dwell-gated
    // good-zone announcement.
    // Atomic arrival (field finding: the cut preceding the chime by the
    // confirmation latency was disorienting): the beacon keeps playing —
    // `inDeadZone: false` forced — until the good-zone episode has FIRED
    // its entry earcon (`dwellFiredForCurrentEpisode`), so the cut and the
    // chime land together. Side benefit: raw-frame zone transits during
    // overshoots no longer blink the tone off. During the confirmation
    // window the error is ~0, so the user hears the pure center tone with
    // the click crescendo at peak — the arrival finishing, not ambiguity.
    let resolved: SonificationTarget?
    if output.analysis.signalState == .ok, let framing = output.framing {
      let arrivalAnnounced = confirmedState == .goodZone && dwellFiredForCurrentEpisode
      if arrivalAnnounced {
        resolved = gazeTrimTarget(output: output, framing: framing)
      } else {
        resolved = SonificationTarget(
          errorX: framing.error.x,
          errorY: framing.error.y,
          distanceError: framing.distanceError,
          inDeadZone: false
        )
      }
    } else {
      resolved = nil
    }

    if resolved == nil, lastContinuousSendWasNil { return }
    lastContinuousSendWasNil = resolved == nil
    await audio.update(resolved)
  }
}
