import AboutFaceCore
import SwiftUI

/// `Config` load/save/reset/export/import and the slider `Binding` helpers
/// (spec §9/§11). Split out of `PipelineModel.swift` purely to keep each
/// file a manageable size (see that file's doc comment); everything here is
/// still `PipelineModel`'s own implementation, not a separate public
/// surface.
extension PipelineModel {

  // MARK: - Live push to the engine, debounced save to disk

  /// Replaces `config`, pushes it to the running engine immediately (§9:
  /// "changing any slider visibly changes engine behavior"), and schedules
  /// a debounced (~1 s) save to disk so a slider being dragged doesn't
  /// generate a disk write per frame.
  public func updateConfig(_ newConfig: Config) {
    config = newConfig
    if let engine {
      Task { await engine.updateConfig(newConfig) }
    }
    scheduleSave()
  }

  func scheduleSave() {
    saveTask?.cancel()
    let snapshot = config
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      guard let url = try? ConfigStore.defaultURL() else { return }
      try? ConfigStore.save(snapshot, to: url)
      await MainActor.run { self?.saveTask = nil }
    }
  }

  // MARK: - Reset to defaults (§9)

  /// Resets one `Config` sub-section (or scalar field) to
  /// `Config.defaults`'s value at the same key path, leaving every other
  /// field untouched (spec §9: "Reset-to-default per section").
  public func resetToDefault<Value>(_ keyPath: WritableKeyPath<Config, Value>) {
    var updated = config
    updated[keyPath: keyPath] = Config.defaults[keyPath: keyPath]
    updateConfig(updated)
  }

  /// Resets the entire `Config` to `Config.defaults` (spec §9: "and
  /// globally"). Callers are expected to confirm with the user first — this
  /// method itself does not prompt (kept UI-decision-free so it stays
  /// trivially testable/callable), matching the task brief's "confirmation
  /// for global."
  public func resetAllToDefaults() {
    updateConfig(.defaults)
  }

  // MARK: - Export / import (§9)

  public func exportConfig(to url: URL) throws {
    try ConfigStore.export(config, to: url)
  }

  public func importConfig(from url: URL) throws {
    let imported = try ConfigStore.importConfig(from: url)
    updateConfig(imported)
  }

  // MARK: - Slider bindings

  /// A `Binding<Double>` over a `Double` `Config` field, routed through
  /// `updateConfig(_:)` on every write so a slider drag gets the same
  /// "push to engine now, save after a debounce" treatment as any other
  /// config change.
  public func binding(_ keyPath: WritableKeyPath<Config, Double>) -> Binding<Double> {
    Binding(
      get: { self.config[keyPath: keyPath] },
      set: { newValue in
        var updated = self.config
        updated[keyPath: keyPath] = newValue
        self.updateConfig(updated)
      }
    )
  }

  /// Same as `binding(_:)` above, but for `Int` `Config` fields — SwiftUI's
  /// `Slider` only speaks `BinaryFloatingPoint`, so this bridges through
  /// `Double`, rounding on write.
  public func intBinding(_ keyPath: WritableKeyPath<Config, Int>) -> Binding<Double> {
    Binding(
      get: { Double(self.config[keyPath: keyPath]) },
      set: { newValue in
        var updated = self.config
        updated[keyPath: keyPath] = Int(newValue.rounded())
        self.updateConfig(updated)
      }
    )
  }

  // MARK: - Errors

  /// Humanizes a `ConfigStore` error for an alert, including the
  /// `newerVersion` case's specific message (task brief: "surface
  /// importConfig errors as alerts — including the newerVersion message").
  public static func describe(_ error: Error) -> String {
    if let storeError = error as? ConfigStore.StoreError {
      switch storeError {
      case .undecodable:
        return "That file isn't a valid About Face configuration."
      case .newerVersion(let found, let supported):
        return
          "That file was saved by a newer version of About Face (schema \(found)); "
          + "this version supports up to schema \(supported). Update About Face to import it."
      }
    }
    return error.localizedDescription
  }
}
