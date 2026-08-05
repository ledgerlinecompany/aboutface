import AboutFaceCore
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
/// ## Confirmations speak through the shared TTS lane, not VoiceOver (fix,
/// maintainer field finding 2026-08-04)
///
/// `monitorToggle` toggles Monitor mode (§5.2) on/off via
/// `PipelineModel.toggleMonitor()` — see `dispatch(_:)`'s `.monitorToggle`
/// case below. This USED TO be announced with
/// `AccessibilityNotification.Announcement`, on the reasoning that a GLOBAL
/// hotkey's whole point is working with no window focused, so a mode change
/// it causes would otherwise be silent and unverifiable. That reasoning was
/// right about the requirement and wrong about the mechanism: VoiceOver
/// suppresses `AccessibilityNotification.Announcement`s posted by an app
/// that is not frontmost — confirmed live by the maintainer, hotkeys fired
/// (Monitor really did toggle) but nothing was heard, making a working
/// global hotkey indistinguishable from a dead one, which is precisely the
/// bug §8's own hotkeys exist to never have. Every confirmation below now
/// speaks instead through `model.speechRenderer` — the single app-lifetime
/// `SpeechRenderer` (§6.3's own TTS, not VoiceOver's) that `PipelineModel`,
/// this type, and `MonitorReminderController` all share (see
/// `PipelineModel.speechRenderer`'s doc comment) — as a closed-vocabulary
/// `Lexicon.Confirmation` phrase, never a raw `String`: the old call sites
/// also violated §6.3/CLAUDE.md's "do not generate phrases dynamically" by
/// posting hand-written strings, which `SpeechRendering.speak(_:)`'s
/// `Lexicon.Phrase`-only signature makes structurally impossible to repeat.
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
  ///
  /// ## Registration failures are surfaced, never swallowed (fix)
  ///
  /// Every action that fails to register — an invalid combo (defense in
  /// depth against a hand-edited `config.json`; `Hotkey.validate()` already
  /// gates this in `AboutFaceCore` and a future settings UI will refuse to
  /// save an invalid one) or a real `RegisterEventHotKey` failure (most
  /// likely: another app already owns the combo) — is collected into
  /// `model.hotkeyRegistrationIssue`, a visible, VoiceOver-readable property
  /// `SetupWindowView` surfaces (same posture as
  /// `PipelineModel.monitorReminderIssue` for the camera-in-use reminder).
  /// Before this fix, `register(action:hotkey:)`'s guard discarded a failed
  /// registration with no record anywhere — the hotkey would then simply
  /// never fire, with nothing to tell a user (sighted or blind) why. A
  /// partial failure never stops the loop: every other binding still
  /// attempts registration, matching this method's existing "six
  /// independent calls" contract.
  func updateRegistrations(_ hotkeys: Config.Hotkeys) {
    unregisterAll()
    var failures: [String] = []
    for (action, hotkey) in hotkeys.all {
      if let validationError = hotkey.validate() {
        failures.append(
          "\(action.displayName) hotkey is invalid (\(validationError)) and was not registered.")
        continue
      }
      if let status = register(action: action, hotkey: hotkey) {
        failures.append(
          "\(action.displayName) hotkey could not be registered (status \(status)) — it may "
            + "already be in use by another app.")
      }
    }
    model?.hotkeyRegistrationIssue = failures.isEmpty ? nil : failures.joined(separator: " ")
  }

  // MARK: - Registration

  private func unregisterAll() {
    for (_, ref) in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
  }

  /// Attempts to register one action's `Hotkey`. Returns `nil` on success;
  /// on failure, returns the `RegisterEventHotKey` `OSStatus` so
  /// `updateRegistrations(_:)` can report exactly what went wrong per
  /// action — see that method's "Registration failures are surfaced" doc
  /// comment for why a failure must never just vanish here.
  @discardableResult
  private func register(action: Config.HotkeyAction, hotkey: Config.Hotkey) -> OSStatus? {
    var hotKeyRef: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: Self.carbonID(for: action))
    let carbonModifiers = Self.carbonModifiers(from: hotkey.modifiers)
    let status = RegisterEventHotKey(
      hotkey.keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    guard status == noErr, let hotKeyRef else { return status }
    hotKeyRefs[action] = hotKeyRef
    return nil
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
  /// `PipelineModel.toggleMonitor()` and speaks the result (see the
  /// type-level doc comment's "Confirmations speak through the shared TTS
  /// lane" section).
  ///
  /// ## Confirmations bypass §7.5 manual silence, on purpose
  ///
  /// Every `Lexicon.Confirmation` phrase below is spoken by calling
  /// `model.speechRenderer.speak(_:)` DIRECTLY — never through
  /// `FeedbackRouter`, which is where §7.5's manual-silence gate
  /// (`setSilenced`) actually lives. That is a deliberate choice, not an
  /// oversight: §7.5 silence exists to suppress AUTOMATIC feedback the user
  /// did not just ask for ("someone just started talking to me"). A hotkey
  /// confirmation is the opposite of automatic — it is the direct,
  /// synchronous response to a key the user just pressed on purpose — so
  /// silencing it would recreate exactly the bug this whole change fixes:
  /// press a key, hear nothing, cannot tell if it worked. This matters most
  /// for `.silence` itself, immediately below: if that press produced no
  /// confirmation, there would be no way to tell whether it just silenced
  /// or unsilenced feedback. (Flagged for the maintainer: this is a
  /// judgment call reasoned from §7.5's own stated purpose, not something
  /// the spec says explicitly one way or the other — overrule by gating
  /// these `speak` calls on `!model.isSilenced` if the "always audible"
  /// behavior is unwanted for the toggle case.)
  private func dispatch(_ action: Config.HotkeyAction) {
    guard let model else { return }
    switch action {
    case .query:
      model.performQuery()
    case .setupToggle:
      openSetupWindowAction?()
    case .monitorToggle:
      Task { @MainActor [weak model] in
        guard let model else { return }
        await Self.toggleMonitorAndConfirm(model: model)
      }
    case .captureTarget:
      let captured = model.captureCurrentPositionAsTarget()
      if !captured {
        // Same fallback phrase `SetupWindowView`'s own "Capture current
        // position as target" button speaks on failure (§9) — kept in sync
        // by hand since `PipelineModel.captureCurrentPositionAsTarget()`
        // itself only speaks on success (see that method's doc comment).
        Task { @MainActor [weak model] in
          await model?.speechRenderer.speak(Lexicon.Confirmation.noFaceToCapture)
        }
      }
    case .repeatLast:
      model.repeatLastAnnouncement()
    case .silence:
      model.toggleSilence()
      Task { @MainActor [weak model] in
        guard let model else { return }
        await Self.confirmSilenceToggle(model: model)
      }
    }
  }

  /// The `.monitorToggle` case's async body, split out of `dispatch(_:)`
  /// purely to keep that method's cyclomatic complexity down (SwiftLint) —
  /// still just the `.monitorToggle` case's own logic, not a separate
  /// public surface. `toggleMonitor()` is async (it may start/stop the
  /// capture session), so this whole confirmation step runs inside the
  /// `Task` `dispatch(_:)` wraps it in.
  private static func toggleMonitorAndConfirm(model: PipelineModel) async {
    let isOn = await model.toggleMonitor()
    // A failed `start()` (no camera selected, permission denied, ...)
    // leaves `captureErrorMessage` set and `isOn == false` — speak the
    // fixed failure phrase rather than a generic "Monitor off.", same "say
    // something specific about failure, not just silence" posture
    // `.captureTarget`'s failure phrase in `dispatch(_:)` already takes.
    // The full dynamic error text stays available in `SetupWindowView`'s
    // "Capture error" section — see `Lexicon.Confirmation
    // .monitorFailedToStart`'s doc comment for why it is not spoken
    // verbatim.
    if model.captureErrorMessage != nil {
      await model.speechRenderer.speak(Lexicon.Confirmation.monitorFailedToStart)
    } else {
      await model.speechRenderer.speak(
        isOn ? Lexicon.Confirmation.monitorOn : Lexicon.Confirmation.monitorOff)
    }
  }

  /// The `.silence` case's confirmation, split out for the same
  /// complexity reason as `toggleMonitorAndConfirm(model:)` above.
  /// `model.toggleSilence()` (called by `dispatch(_:)` before this `Task`
  /// is created) flips `isSilenced` synchronously before its own internal
  /// `Task` fires (see that method's doc comment), so reading it here
  /// already reflects the NEW state.
  private static func confirmSilenceToggle(model: PipelineModel) async {
    await model.speechRenderer.speak(
      model.isSilenced ? Lexicon.Confirmation.silenced : Lexicon.Confirmation.unsilenced)
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
