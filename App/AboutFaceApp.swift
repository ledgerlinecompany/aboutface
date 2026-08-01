import AboutFaceCore
import SwiftUI

/// The Phase 2 app shell (spec §13 Phase 2, §9): a Setup window and a
/// separate Debug Panel window, both bound to one shared `PipelineModel`
/// instance so starting the camera in one and adjusting a slider in the
/// other both affect the same running `AnalysisEngine`.
///
/// `LSUIElement` (menu-bar-only, §5.2) is deliberately NOT set yet —
/// Monitor mode arrives in Phase 4, and a Dock icon makes Phase 2/3
/// development and VoiceOver testing easier (see `project.yml`'s matching
/// comment).
@main
struct AboutFaceApp: App {
  @State private var model = PipelineModel()

  var body: some Scene {
    WindowGroup("About Face — Setup", id: "setup") {
      SetupWindowView(model: model)
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
  }
}
