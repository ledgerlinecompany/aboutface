import AboutFaceCore
import SwiftUI

/// §16.4's minimal `MenuBarExtra` content: shows the current mode, toggles
/// Monitor, and opens the Setup window — the three things a mostly-
/// background app needs one always-reachable surface for. `AboutFaceApp`
/// keeps its Dock icon this PR (task brief: "Do NOT set `LSUIElement`...
/// The app keeps its Dock icon this PR"), so this menu is an ADDITIONAL
/// surface, not the app's only one yet.
///
/// Deliberately thin (CLAUDE.md: "keep `App/` thin") — every row reads
/// `PipelineModel` state directly and calls existing entry points
/// (`toggleMonitor()`, `openWindow`); no signal math or mode-transition
/// decisions live here.
///
/// ## Accessibility (task brief, §16.4)
///
/// "Every element VoiceOver-navigable with a meaningful label AND value —
/// a menu item reading just 'Monitor' with no indication of whether it is
/// ON is exactly the failure this project exists to avoid." Both rows
/// below state their OWN current state directly in an explicit
/// `accessibilityValue` rather than relying on a checkmark or icon glyph a
/// screen reader might not expose.
struct MenuBarContentView: View {
  @Bindable var model: PipelineModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(modeStatusText)
      .accessibilityLabel("Mode")
      .accessibilityValue(modeStatusText)

    Divider()

    Button(monitorButtonTitle) {
      Task { await model.toggleMonitor() }
    }
    .accessibilityLabel("Monitor")
    .accessibilityValue(monitorIsOn ? "On" : "Off")
    .accessibilityHint(
      "Toggles Monitor mode: background, earcons-only feedback for use during a call."
    )

    Divider()

    Button("Open Setup Window") {
      openWindow(id: "setup")
    }
  }

  private var monitorIsOn: Bool {
    model.isRunning && model.mode == .monitor
  }

  /// §6.1's silence-ambiguity lesson applies to this row too: "Stopped" is
  /// its own explicit value, never inferred from the absence of a "Setup"
  /// or "Monitor" line.
  private var modeStatusText: String {
    guard model.isRunning else { return "Stopped" }
    switch model.mode {
    case .setup: return "Setup"
    case .monitor: return "Monitor"
    }
  }

  private var monitorButtonTitle: String {
    monitorIsOn ? "Turn Monitor Off" : "Turn Monitor On"
  }
}
