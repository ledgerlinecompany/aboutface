/// §16.4's "app configured" predicate — the maintainer's decision (task
/// brief for the Phase 4 monitor-triggers PR) on the open question §16.4
/// itself raises ("Whether Monitor mode should auto-enable on camera-in-use
/// by default, or require explicit opt-in per profile"): Monitor MAY
/// auto-activate on a busy camera (§12.2, `CameraGatingStateMachine`'s
/// `free → busy` / `.off` row in `CameraGating.swift`'s rules table) ONLY
/// when the app is configured — never on a fresh, unconfigured install,
/// where auto-starting audio feedback the moment someone joins their first
/// call would be alarming and inexplicable to a user who has never touched
/// this app before.
///
/// Split out of `Config+Camera.swift` into its own file because this
/// predicate is not really a camera concern — it reads BOTH
/// `Config.Camera.selectedCameraID` and `Config.TargetFraming.captured` —
/// and giving it a dedicated file keeps it discoverable rather than buried
/// in either sub-config's own file.
extension Config {
  /// "Configured" means the user has EXPLICITLY set something up:
  ///
  /// - An explicitly chosen camera (§12.1: "User explicitly selects the
  ///   camera") — `Config.Camera.selectedCameraID != nil`. `nil` means
  ///   "system default," which a fresh install already has without the user
  ///   ever having made a choice.
  /// - A captured framing target (§4's "capture current position as
  ///   target") — `Config.TargetFraming.captured`. See that field's own doc
  ///   comment for why this is an explicit marker rather than a heuristic
  ///   comparison against `Config.defaults.targetFraming`.
  ///
  /// Either alone is enough: a user who has picked a specific camera but
  /// not yet captured a target has still told this app something about how
  /// they use it, and the same is true in reverse. Fresh, untouched
  /// defaults on both counts is the only `false` case.
  public var isConfigured: Bool {
    camera.selectedCameraID != nil || targetFraming.captured
  }
}
