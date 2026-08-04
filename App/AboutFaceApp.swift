import AboutFaceCore
import SwiftUI

/// The app shell (spec §13 Phase 2/4, §9): a Setup window, a Debug Panel
/// window, and (as of §16.4) a `MenuBarExtra`, all bound to one shared
/// `PipelineModel` instance so starting the camera in one and adjusting a
/// slider in another both affect the same running `AnalysisEngine`.
///
/// `LSUIElement` (menu-bar-only) is deliberately NOT set, and is not to be
/// set later — a decided packaging choice (maintainer, 2026-08-04) that
/// REVERSES §5.2's original prescription rather than merely deferring it.
/// Removing the Dock icon also removes About Face from Cmd-Tab, and the
/// Setup window (§9) is a real window a blind user needs a reliable,
/// discoverable route back to; that access was judged worth more than a
/// menu-bar-only presence for this audience. The `MenuBarExtra` below is an
/// ADDITIONAL surface alongside the Dock icon, never a replacement for it.
/// See §5.2 before reconsidering.
@main
struct AboutFaceApp: App {
  @State private var model = PipelineModel()
  // §8 global hotkeys: one `HotkeyCenter` for the app's lifetime, wired up
  // (and re-wired on `Config.hotkeys` changes) from the Setup window's own
  // `.task`/`.onChange` below — see `SetupWindowView`'s
  // `hotkeyBootstrap` doc comment for why that is the right place rather
  // than here.
  @State private var hotkeyCenter = HotkeyCenter()
  // §12.2/§16.4 camera-in-use reminder: one instance for the app's
  // lifetime, same "@State on AboutFaceApp" pattern as `hotkeyCenter` —
  // see `MonitorReminderController`'s doc comment for why it must outlive
  // any single pipeline run.
  @State private var monitorReminderController = MonitorReminderController()

  var body: some Scene {
    WindowGroup("About Face — Setup", id: "setup") {
      SetupWindowView(
        model: model, hotkeyCenter: hotkeyCenter,
        monitorReminderController: monitorReminderController
      )
      .frame(minWidth: 480, minHeight: 420)
    }
    .defaultSize(width: 560, height: 680)

    // A single, non-duplicating window (`Window`, not `WindowGroup`) — the
    // debug panel edits one shared `Config`, so more than one copy open at
    // once would be confusing rather than useful.
    Window("About Face — Debug Panel", id: "debug-panel") {
      DebugPanelView(model: model)
        .frame(minWidth: 480, minHeight: 420)
    }
    .defaultSize(width: 560, height: 760)

    // §16.4's minimal menu bar surface (task brief part 4): current mode,
    // Monitor toggle, and a way back into the Setup window — see
    // `MenuBarContentView`'s doc comment for the accessibility contract.
    MenuBarExtra("About Face", systemImage: "video") {
      MenuBarContentView(model: model)
    }
  }
}
