import AboutFaceCore
import SwiftUI

/// The dismissible/acknowledgeable notice rows `SetupWindowView.body` shows
/// alongside its Setup controls (§12.3/§12.4/§9's config-load notice). Split
/// from `SetupWindowView.swift` purely for SwiftLint's file-length limit —
/// same pattern as `DebugPanelView`'s own `+Audio.swift` split. §12.5's own
/// notice (`model.centerStageNotice`) has no row of its own here: it is a
/// plain, non-dismissible `Text` built directly into `body` (see that
/// property's `Section("Center Stage")` for why — there is nothing to
/// acknowledge or dismiss, see `CenterStageStateMachine`'s doc comment).
extension SetupWindowView {
  /// §12.3's "never blocking... dismissible" notice row: the message text
  /// plus a "Dismiss" button, both one VoiceOver-navigable unit's worth of
  /// controls rather than a bare `Text` — a blind user needs an obvious,
  /// discoverable way to act on this, not just to hear it. Dismissing calls
  /// straight through to `CameraMismatchController.dismiss()`, which is the
  /// only thing that changes `model.cameraMismatchWarning`; this view does
  /// no state of its own (CLAUDE.md: keep `App/` thin).
  func cameraMismatchNoticeRow(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message)
        .foregroundStyle(.orange)
      Button("Dismiss") {
        cameraMismatchController.dismiss()
      }
      .accessibilityHint(
        "Dismisses this notice until the condition clears and a new mismatch is detected.")
    }
  }

  /// §12.4's one-time acknowledgeable warning. "Acknowledge" rather than
  /// "Dismiss" on purpose: unlike the mismatch notice above, this one does
  /// not come back on its own once accepted — it is a standing fact about
  /// this device, recorded per-uniqueID in `Config` and persisted across
  /// launches, so the button's label should promise exactly that rather
  /// than implying a temporary silence.
  func virtualCameraNoticeRow(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message)
        .foregroundStyle(.orange)
      Button("Acknowledge") {
        model.acknowledgeVirtualCamera()
      }
      .accessibilityHint(
        "Records that you know this camera is virtual. This notice will not appear again for "
          + "this camera, on this or any future launch. Other cameras are unaffected.")
    }
  }

  func configLoadIssueRow(_ issue: ConfigStore.LoadIssue) -> some View {
    Group {
      switch issue {
      case .missing:
        Text("No saved configuration found — using defaults.")
      case .corruptBackedUp(let backupURL):
        Text(
          "Your saved configuration could not be read and was reset to defaults. "
            + "The original file was kept at \(backupURL.path)."
        )
      }
    }
    .foregroundStyle(.secondary)
    .disabled(!model.isRunning)
  }
}
