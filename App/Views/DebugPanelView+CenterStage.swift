import SwiftUI

/// §12.5's debug-panel override control. Split from `DebugPanelView.swift`
/// purely for SwiftLint's file-length limit — same pattern as
/// `DebugPanelView+Audio.swift` (see that file's doc comment).
extension DebugPanelView {
  /// Forces the value `CenterStageController` feeds to
  /// `FeedbackRouter.setCenterStageActive(_:at:)`, so the maintainer can
  /// judge Center Stage's feedback suppression by ear without depending on
  /// the poller — or real Center-Stage-capable hardware — being available.
  /// See `PipelineModel.centerStageDebugOverride`'s doc comment for why this
  /// is a tri-state (`nil`/`true`/`false`), not a plain `Bool`: "not
  /// overridden" must be representable and distinct from "overridden to
  /// off." The warning text below is not decorative — the override must
  /// never be mistaken for a real reading (task brief), so it is spelled out
  /// in words whenever it is anything other than "Follow real signal," not
  /// left to the Picker's own selection state to communicate.
  var centerStageOverrideSection: some View {
    Section("Center Stage override (debug)") {
      Picker(
        "Center Stage override",
        selection: Binding(
          get: { model.centerStageDebugOverride },
          set: { model.centerStageDebugOverride = $0 }
        )
      ) {
        Text("Follow real signal").tag(Bool?.none)
        Text("Force on").tag(Bool?.some(true))
        Text("Force off").tag(Bool?.some(false))
      }
      .pickerStyle(.segmented)
      .accessibilityHint(
        "For judging Center Stage's feedback suppression by ear. Forcing on or off overrides "
          + "whatever the real camera reports until set back to Follow real signal."
      )

      if let override = model.centerStageDebugOverride {
        Text(
          "Debug override engaged: forcing Center Stage \(override ? "ON" : "OFF"). "
            + "This is NOT a real reading — set back to Follow real signal to resume it."
        )
        .foregroundStyle(.orange)
      }

      // Unlike the override above, this is NOT a debug-only control — it is a
      // real `Config` value (`FeedbackConfig.centerStageArrivalChimeEnabled`)
      // that persists and ships. It lives in this section because it is only
      // meaningful alongside the override, which is what makes it possible to
      // A/B by ear without Center-Stage-capable hardware to hand. §12.5.
      Toggle(
        "Arrival chime under Center Stage",
        isOn: model.boolBinding(\.feedback.centerStageArrivalChimeEnabled)
      )
      .accessibilityHint(
        "When on, the good-zone arrival chime still sounds while Center Stage is framing you. "
          + "The spoken Centered. is always suppressed under Center Stage regardless, because it "
          + "is a framing claim the app cannot make while the system owns the crop."
      )
    }
  }
}
