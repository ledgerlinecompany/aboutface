import AboutFaceCore
import Accessibility
import Carbon.HIToolbox

/// §8's App-side Carbon wrapper: "Registered with `RegisterEventHotKey`,
/// **not** `CGEventTap`. Event taps require the Accessibility TCC permission
/// and are an App Store non-starter." Thin by design (CLAUDE.md: "keep
/// `App/` thin") — every hard rule (no Option, no modifier-less combo) and
/// every default binding lives in `Config+Hotkeys.swift`
/// (`AboutFaceCore`, testable without Carbon); this type only turns an
/// already-validated `Config.Hotkeys` into real `RegisterEventHotKey`
/// registrations and forwards fired actions to `PipelineModel`.
///
/// `monitorToggle` toggles Monitor mode (§5.2) on/off via
/// `PipelineModel.toggleMonitor()` — see `dispatch(_:)`'s `.monitorToggle`
/// case below. Announced with `AccessibilityNotification.Announcement`
/// (same mechanism `.captureTarget`'s failure path already uses) because a
/// GLOBAL hotkey's whole point is working with no window focused, which
/// means a mode change it causes would otherwise be completely silent and
/// unverifiable for a blind user.
///
/// ## Concurrency
///
/// `InstallEventHandler`'s callback is a plain C function pointer
/// (`@convention(c)`) — it cannot capture Swift context, so it captures
/// nothing and reads only its own parameters, matching CLAUDE.md's
/// toolchain rule to never let a non-`Sendable`/cross-isolation value leak
/// across an opaque C boundary implicitly. The only value that crosses the
/// C boundary into the `Task { @MainActor in }` hop is the fired combo's
/// plain `UInt32` ID — trivially `Sendable`. The live instance is reached
/// via the weak `Self.current` static, resolved only once already on the
/// main actor (see that property's doc comment for why not Carbon's
/// `inUserData` raw pointer).
@MainActor
final class HotkeyCenter {
  private var eventHandlerRef: EventHandlerRef?
  private var hotKeyRefs: [Config.HotkeyAction: EventHotKeyRef] = [:]
  private weak var model: PipelineModel?
  private var openSetupWindowAction: (() -> Void)?

  /// How a fired hotkey finds its way back to the live instance — a WEAK
  /// static, deliberately not Carbon's `inUserData` raw pointer: the C
  /// callback hands off to a `Task { @MainActor }`, and a raw pointer
  /// captured by that task could be dereferenced AFTER `deinit` freed the
  /// object (callback fires, app tears down, task runs — dangling pointer,
  /// undefined behavior at quit). A weak reference read on the main actor
  /// simply resolves to `nil` in that window instead. The app only ever
  /// creates one `HotkeyCenter` (`AboutFaceApp`'s single `@State`); if a
  /// second were ever created, latest-wins here, matching what Carbon
  /// itself would do with duplicate registrations.
  private static weak var current: HotkeyCenter?

  /// Carbon's four-char-code hotkey "signature," namespacing this app's
  /// hotkey IDs — arbitrary but stable across launches (it is never
  /// persisted or compared against another process, so any stable value
  /// works; this spells "AFHK" in ASCII purely as a mnemonic).
  private static let signature: OSType = 0x4146_484B

  init() {
    installEventHandler()
    Self.current = self
  }

  /// A plain `deinit` on an `@MainActor` class is `nonisolated` by default
  /// (Swift 6 strict concurrency does not isolate deinitializers), so
  /// touching `eventHandlerRef`/`hotKeyRefs` directly here doesn't compile.
  /// `MainActor.assumeIsolated` is sound: `HotkeyCenter`'s only owner is
  /// `AboutFaceApp`'s `@State`, which — like every `@State` — is only ever
  /// created, read, or torn down on the main actor, so deinit for THIS type
  /// specifically never runs anywhere else.
  deinit {
    MainActor.assumeIsolated {
      if let eventHandlerRef {
        RemoveEventHandler(eventHandlerRef)
      }
      for (_, ref) in hotKeyRefs {
        UnregisterEventHotKey(ref)
      }
    }
  }

  /// Wires this center to a running `PipelineModel` and registers its
  /// current `Config.hotkeys`. Call once at app startup (see
  /// `AboutFaceApp`'s `.task`); `updateRegistrations(_:)` is the entry
  /// point for later `Config` changes (a live-tuning settings UI is Phase
  /// 5 scope — not built this round — but the re-registration path is
  /// already here for it to call into).
  func configure(model: PipelineModel, openSetupWindow: @escaping () -> Void) {
    self.model = model
    self.openSetupWindowAction = openSetupWindow
    updateRegistrations(model.config.hotkeys)
  }

  /// Re-registers every binding from scratch — the simplest correct
  /// response to a `Config.hotkeys` change (§9's "changing any slider
  /// visibly changes engine behavior" precedent, applied here to hotkey
  /// bindings): six cheap `RegisterEventHotKey` calls, never on a hot path,
  /// so there is no reason to diff old vs. new and only touch what moved.
  func updateRegistrations(_ hotkeys: Config.Hotkeys) {
    unregisterAll()
    for (action, hotkey) in hotkeys.all {
      // §8 hard rule, defense in depth: `Hotkey.validate()` already gates
      // this in `AboutFaceCore`, and a future settings UI will refuse to
      // save an invalid combo in the first place — but a hand-edited
      // `config.json` could still reach this call directly. Never let an
      // Option-inclusive or modifier-less combo reach a real
      // `RegisterEventHotKey` call; silently skip it instead of crashing
      // or partially registering the other five.
      guard hotkey.validate() == nil else { continue }
      register(action: action, hotkey: hotkey)
    }
  }

  // MARK: - Registration

  private func unregisterAll() {
    for (_, ref) in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
  }

  private func register(action: Config.HotkeyAction, hotkey: Config.Hotkey) {
    var hotKeyRef: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: Self.carbonID(for: action))
    let carbonModifiers = Self.carbonModifiers(from: hotkey.modifiers)
    let status = RegisterEventHotKey(
      hotkey.keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    guard status == noErr, let hotKeyRef else { return }
    hotKeyRefs[action] = hotKeyRef
  }

  /// Installs the single process-wide Carbon event handler that every
  /// registered hotkey's `kEventHotKeyPressed` event arrives through. The
  /// handler closure is intentionally capture-free (see the type-level doc
  /// comment's Concurrency section) — `self` is reached through the weak
  /// `Self.current` static, resolved only once already on the main actor
  /// (see that property's doc comment for why not Carbon's `inUserData`
  /// raw pointer: a raw pointer captured by the Task could dangle at app
  /// teardown; a weak reference just resolves to `nil`).
  private func installEventHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, eventRef, _ in
        guard let eventRef else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr else { return status }
        // Only a `Sendable` `UInt32` crosses into the Task below — see the
        // type-level doc comment's Concurrency section.
        let carbonID = hotKeyID.id
        Task { @MainActor in
          HotkeyCenter.current?.handleFiredHotKey(carbonID: carbonID)
        }
        return noErr
      }, 1, &eventType, nil, &eventHandlerRef)
  }

  private func handleFiredHotKey(carbonID: UInt32) {
    guard let action = Self.action(forCarbonID: carbonID) else { return }
    dispatch(action)
  }

  // MARK: - Action dispatch

  /// Forwards a fired action to `PipelineModel`. Wiring per the task brief:
  /// `query`/`repeatLast` are new (§5.3/§8); `setupToggle`/`captureTarget`/
  /// `silence` reuse existing `PipelineModel` entry points (the same ones
  /// the Setup window's own buttons already call); `monitorToggle` calls
  /// `PipelineModel.toggleMonitor()` and announces the result (see the
  /// type-level doc comment).
  private func dispatch(_ action: Config.HotkeyAction) {
    guard let model else { return }
    switch action {
    case .query:
      model.performQuery()
    case .setupToggle:
      openSetupWindowAction?()
    case .monitorToggle:
      // `toggleMonitor()` is async (it may start/stop the capture
      // session); `dispatch(_:)` itself stays synchronous like every other
      // case, so the async work and its announcement are wrapped in one
      // `Task`. `[weak model]` avoids extending the model's lifetime past
      // this task for what is normally a near-instant await.
      Task { @MainActor [weak model] in
        guard let model else { return }
        let isOn = await model.toggleMonitor()
        // A failed `start()` (no camera selected, permission denied, ...)
        // leaves `captureErrorMessage` set and `isOn == false` — surface
        // that specific reason rather than a generic "Monitor off.", same
        // "say what actually happened" posture `.captureTarget`'s failure
        // announcement below already takes.
        if let error = model.captureErrorMessage {
          AccessibilityNotification.Announcement(error).post()
        } else {
          AccessibilityNotification.Announcement(isOn ? "Monitor on." : "Monitor off.").post()
        }
      }
    case .captureTarget:
      let captured = model.captureCurrentPositionAsTarget()
      if !captured {
        // Same fallback announcement `SetupWindowView`'s own "Capture
        // current position as target" button posts on failure (§9) — kept
        // in sync by hand since `PipelineModel.captureCurrentPositionAsTarget()`
        // itself only announces success (see that method's doc comment).
        AccessibilityNotification.Announcement("No face detected — nothing to capture").post()
      }
    case .repeatLast:
      model.repeatLastAnnouncement()
    case .silence:
      model.toggleSilence()
    }
  }

  // MARK: - Carbon ID <-> Config.HotkeyAction

  /// Stable per-action IDs for `EventHotKeyID.id` — arbitrary but must stay
  /// fixed for a given action across `register(action:hotkey:)`/
  /// `action(forCarbonID:)` round-trips within one process run (they are
  /// never persisted, so nothing depends on the specific numbers beyond
  /// that).
  private static func carbonID(for action: Config.HotkeyAction) -> UInt32 {
    switch action {
    case .query: return 1
    case .setupToggle: return 2
    case .monitorToggle: return 3
    case .captureTarget: return 4
    case .repeatLast: return 5
    case .silence: return 6
    }
  }

  private static func action(forCarbonID carbonID: UInt32) -> Config.HotkeyAction? {
    switch carbonID {
    case 1: return .query
    case 2: return .setupToggle
    case 3: return .monitorToggle
    case 4: return .captureTarget
    case 5: return .repeatLast
    case 6: return .silence
    default: return nil
    }
  }

  /// `Config.Modifier` (platform-independent, `AboutFaceCore`) to Carbon's
  /// `UInt32` modifier bitmask. `.option` is translated too, even though
  /// `Hotkey.validate()` should always exclude it from anything reaching
  /// this method — translating it faithfully rather than silently dropping
  /// it means a bug in the validation gate would be immediately audible
  /// (the combo would actually register with Option) rather than silently
  /// registering a DIFFERENT, unintended combo.
  private static func carbonModifiers(from modifiers: Set<Config.Modifier>) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    if modifiers.contains(.option) { result |= UInt32(optionKey) }
    return result
  }
}
