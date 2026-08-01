/// §7.4's priority ladder, encoded as an ordered, `Config`-independent
/// `CaseIterable` enum: "when several conditions are true, announce only
/// the top one." `FeedbackCondition.allCases` (Swift's compiler-synthesized
/// iteration order for a plain `enum`, which is declaration order) IS the
/// ladder — `FeedbackRouter.discreteState(for:)` below walks it top to
/// bottom and takes the first case whose gate is true, so the ladder's
/// order lives in exactly one place (this declaration) rather than a
/// separately-maintained array that could drift out of sync with it.
///
/// Each case's gate lives in `Gates.evaluate(_:output:)`. Two of §7.4's
/// seven numbered rungs are intentionally NOT wired to real signals this
/// phase — their gates always return `false` — because the signal they'd
/// need doesn't exist yet:
///
/// - `.partiallyOutOfFrame` (§7.4 rung 3) needs bbox-edge logic: comparing
///   `FaceGeometry.boundingBox` against the frame's own bounds to detect a
///   face brushing an edge. `FaceGeometry` doesn't currently distinguish
///   "small/far away" from "cropped by the frame edge," and building that
///   distinction is out of this round's scope. Phase 4 fills in
///   `Gates.partiallyOutOfFrame`.
/// - `.lightingCritical` (§7.4 rung 4) needs a "lighting is bad enough that
///   a face is effectively undetectable" threshold over `LightingMetrics`
///   that doesn't exist in `Config` or `FeedbackConfig` yet. Phase 4 fills
///   in `Gates.lightingCritical` (and, per this round's scope note, the
///   threshold itself likely belongs in `Config.swift`, which this branch
///   does not touch).
///
/// `.lowConfidence` is NOT one of §7.4's seven numbered rungs, but §6.1
/// requires it to be "audibly distinct from both [good zone and face
/// lost]," and `SignalState.lowConfidence` has been available since Phase
/// 1 — unlike the two stubs above, there's no reason to leave it
/// unimplemented. It sits adjacent to `.lightingCritical` because both
/// represent "the detector can't get a trustworthy read, usually because of
/// light" (see `SignalState.lowConfidence`'s own doc comment: "often = too
/// dark").
///
/// §7.4 rung 7 ("minor lighting / other people / everything else") has no
/// case here at all — there is no lighting-severity classification or
/// other-people signal to gate on yet, so there is nothing for a case to
/// represent. Phase 4/5 adds cases as those signals land; nothing about
/// this design requires them to slot in at the end, since `allCases`
/// order is just declaration order and a new case can be inserted wherever
/// its priority belongs.
///
/// `Hashable` so `FeedbackRouter` can key its §5.2 per-condition rate-limit
/// timestamps (`lastAnnouncementAtByCondition`) directly off this type.
public enum FeedbackCondition: Sendable, Equatable, Hashable, CaseIterable {
  /// §7.4 rung 1.
  case noSignal
  /// §7.4 rung 2.
  case faceLost
  /// §7.4 rung 3 — gate stubbed `false`, see type-level doc comment.
  case partiallyOutOfFrame
  /// §7.4 rung 4 — gate stubbed `false`, see type-level doc comment.
  case lightingCritical
  /// Not a numbered §7.4 rung; see type-level doc comment.
  case lowConfidence
  /// §7.4 rung 5.
  case framingError
  /// §7.4 rung 6.
  case gazeOff
}

/// A frame's fully-resolved discrete state: either a `FeedbackCondition`
/// problem (§7.4), the no-problem `.goodZone` state (§6.1 — deliberately
/// NOT part of the priority ladder above, since it's the ladder's
/// complement, not one of its rungs), or `.indeterminate` for the
/// defensive fallback case where `EngineOutput` doesn't carry enough
/// information to classify (see `FeedbackRouter.discreteState(for:)`).
enum DiscreteState: Sendable, Equatable {
  case problem(FeedbackCondition)
  case goodZone
  case indeterminate
}

extension FeedbackRouter {
  /// §7.4 gate predicates, one per `FeedbackCondition` case, in the same
  /// order as the enum so the two stay easy to eyeball against each other.
  enum Gates {
    static func evaluate(_ condition: FeedbackCondition, output: EngineOutput) -> Bool {
      switch condition {
      case .noSignal:
        return output.analysis.signalState == .noSignal
      case .faceLost:
        return output.analysis.signalState == .noFace
      case .partiallyOutOfFrame:
        return false
      case .lightingCritical:
        return false
      case .lowConfidence:
        return output.analysis.signalState == .lowConfidence
      case .framingError:
        return output.framing.map { !$0.inDeadZone } ?? false
      case .gazeOff:
        return output.framing.map { $0.inDeadZone && !$0.gazeOnCamera } ?? false
      }
    }
  }

  /// Resolves one frame's `EngineOutput` to a `DiscreteState` by walking
  /// §7.4's ladder (`FeedbackCondition.allCases`, top to bottom) and taking
  /// the first matching gate. If none match, the frame is either
  /// `.goodZone` (signal `.ok`, framing present, in dead zone, gaze on
  /// camera) or `.indeterminate` — the latter is a defensive fallback for a
  /// `.ok` signal state with no `framing` (a contract violation by
  /// `AnalysisEngine`'s own documented invariant, "framing is nil exactly
  /// when analysis.primary is nil," which should be unreachable when
  /// `signalState == .ok`) and never drives an announcement (see
  /// `tickAnnouncements(output:at:)`'s `.indeterminate` case).
  static func discreteState(for output: EngineOutput) -> DiscreteState {
    if let condition = FeedbackCondition.allCases.first(where: {
      Gates.evaluate($0, output: output)
    }) {
      return .problem(condition)
    }
    // swift-format requires the brace on its own line after a multiline
    // condition; swiftlint's opening_brace rule disagrees. Format wins.
    // swiftlint:disable opening_brace
    if output.analysis.signalState == .ok, let framing = output.framing, framing.inDeadZone,
      framing.gazeOnCamera
    {
      // swiftlint:enable opening_brace
      return .goodZone
    }
    return .indeterminate
  }
}
