import AboutFaceCore
import SwiftUI

/// Minimal app shell for the Phase 2 build-out (spec §13). This placeholder
/// window proves the app target links `AboutFaceCore` and carries the §2
/// entitlements; the real Setup window and debug panel (spec §9) replace
/// its content in Phase 2 proper.
@main
struct AboutFaceApp: App {
  var body: some Scene {
    WindowGroup("About Face") {
      ContentView()
    }
  }
}

struct ContentView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("About Face")
        .font(.title)
      Text("Phase 2 (Setup window and debug panel) is under construction.")
      Text("Core config schema version: \(Config.defaults.version)")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(minWidth: 420, minHeight: 200, alignment: .topLeading)
  }
}
