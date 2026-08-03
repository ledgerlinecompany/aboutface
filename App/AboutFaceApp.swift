import AboutFaceCore
import SwiftUI

/// The app shell (spec §13 Phase 2/4, §9): a Setup window, a Debug Panel
/// window, and (as of §16.4) a `MenuBarExtra`, all bound to one shared
/// `PipelineModel` instance so starting the camera in one and adjusting a
/// slider in another both affect the same running `AnalysisEngine`.
///
/// `LSUIElement` (menu-bar-only, §5.2) is deliberately NOT set — that is an
/// explicit maintainer packaging decision, not this PR's to make (task
/// brief). The `MenuBarExtra` below is an ADDITIONAL surface alongside the
/// Dock icon, which still makes VoiceOver testing and normal window
/// management easier during development.
@main
struct AboutFaceApp: App {
  @State private var model = PipelineModel()
  // §8 global hotkeys: one `HotkeyCenter` for the app's lifetime, wired up
  // (and re-wired on `Config.hotkeys` changes) from the Setup window's own
  // `.task`/`.onChange` below — see `SetupWindowView`'s
  // `hotkeyBootstrap` doc comment for why that is the right place rather
  // than here.
  @State private var hotkeyCenter = HotkeyCenter()

  var body: some Scene {
    WindowGroup("About Face — Setup", id: "setup") {
      SetupWindowView(model: model, hotkeyCenter: hotkeyCenter)
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
