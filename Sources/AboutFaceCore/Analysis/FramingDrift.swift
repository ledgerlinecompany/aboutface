/// Whether the user has drifted far enough outside §4's dead zone to be worth
/// a quiet nudge — the primary signal behind Phase 4.5's status pulse
/// (`docs/design/phase-4.5-app-design.md` §3.3.1).
///
/// ## Why this replaced edge-cropping as the primary trigger
///
/// The pulse's bit was first driven only by `FrameEdgeCrop`. Live session,
/// 2026-08-08: *"I couldn't actually get myself cropped; every adjustment was
/// normal heartbeat until the face lost earcon."*
///
/// Vision detects a FACE, not a head, and it stops detecting well before the
/// box it reports gets clipped by the frame. So a user moving out of shot goes
/// straight from "comfortably framed" to "no face," with no intermediate state
/// for the bit to describe. The condition was real but effectively
/// unreachable — which reasoning did not reveal and one session did.
///
/// What the user actually wanted was the thing he named in the same breath:
/// *"I did wonder if I had moved too much without any kind of indicator."*
/// That is DRIFT, and it is continuously reachable.
///
/// ## Why a multiple of the dead zone rather than its own thresholds
///
/// §4's dead zone is already tuned by ear across three axes. A second,
/// independent set of numbers would be two definitions of "well placed" to
/// keep in sync, and §0's whole posture is one canonical place per tunable.
/// Scaling the existing thresholds gives a widened boundary for free and keeps
/// the relationship between them ("the warn zone is twice the good zone")
/// legible.
public enum FramingDrift {
  /// Whether `framing` is outside the dead zone scaled by `multiplier`, on any
  /// axis.
  ///
  /// Any single axis is enough, deliberately: being badly off horizontally is
  /// not excused by being perfectly placed vertically, and §4 treats the three
  /// axes as independently satisfiable for the same reason.
  ///
  /// A `multiplier` at or below 1 would put the warn boundary inside the good
  /// zone, so the pulse would flag a user the app simultaneously considers
  /// well placed. Clamped rather than trusted — a nonsensical config should
  /// degrade to "never warns," not to "always warns."
  public static func hasDrifted(
    framing: FramingState, deadZone: Config.DeadZone, multiplier: Double
  ) -> Bool {
    guard multiplier >= 1 else { return false }
    let horizontal = deadZone.horizontal * multiplier
    let vertical = deadZone.vertical * multiplier
    let distance = deadZone.distance * multiplier
    if abs(Double(framing.error.x)) > horizontal { return true }
    if abs(Double(framing.error.y)) > vertical { return true }
    if abs(Double(framing.distanceError)) > distance { return true }
    return false
  }
}
