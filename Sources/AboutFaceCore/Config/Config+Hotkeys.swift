/// §8 global hotkeys, modeled entirely in the platform-independent core so
/// the hard rules below are unit-testable without Carbon (CLAUDE.md:
/// `AboutFaceCore` is "platform-independent... capture, backends, analysis,
/// feedback routing"). `App/`'s `HotkeyCenter` is the one place that turns
/// these plain values into real `RegisterEventHotKey` calls — see its doc
/// comment for the App-side half of this contract.
///
/// Split out of `Config.swift` into this file purely to keep that file's own
/// diff minimal (a sibling branch is concurrently editing `Config.swift`'s
/// property list — see this file's companion edit there, which is limited to
/// one stored property, one init parameter, and one `defaults` line) and to
/// stay under SwiftLint's `file_length`/`type_body_length` limits, matching
/// the `Config+Audio.swift`/`Config+AudioEarcons.swift` precedent: every type
/// below is still `Config`-nested (`Config.Hotkeys`, `Config.Hotkey`, ...),
/// declared via `extension Config { ... }`, exactly as if it lived inline in
/// `Config.swift`.
extension Config {
  /// One binding per §8 action, all reconfigurable in settings (§8: "Default
  /// set — all reconfigurable in settings").
  public struct Hotkeys: Codable, Sendable, Equatable {
    /// ⌘⌃⇧F default — "the most-used key" (§8, §5.3).
    public var query: Hotkey
    /// ⌘⌃⇧S default — opens/focuses the Setup window.
    public var setupToggle: Hotkey
    /// ⌘⌃⇧M default — Monitor mode toggle. Registered even though the
    /// Monitor controller itself is a sibling PR's scope (this round wires
    /// the hotkey and a no-op stub — see `HotkeyCenter`'s doc comment).
    public var monitorToggle: Hotkey
    /// ⌘⌃⇧T default — "capture current position as target" (§4).
    public var captureTarget: Hotkey
    /// ⌘⌃⇧R default — repeat last announcement (§8).
    public var repeatLast: Hotkey
    /// ⌘⌃⇧/ default — §7.5 manual silence.
    public var silence: Hotkey

    public init(
      query: Hotkey,
      setupToggle: Hotkey,
      monitorToggle: Hotkey,
      captureTarget: Hotkey,
      repeatLast: Hotkey,
      silence: Hotkey
    ) {
      self.query = query
      self.setupToggle = setupToggle
      self.monitorToggle = monitorToggle
      self.captureTarget = captureTarget
      self.repeatLast = repeatLast
      self.silence = silence
    }

    /// §8's default table, verbatim: "⌘⌃⇧" + F/S/M/T/R/slash. Key codes are
    /// AppKit/Carbon virtual key codes for a US ANSI keyboard layout (see
    /// `Hotkey.keyCode`'s doc comment) — `0x03`=F, `0x01`=S, `0x2E`=M,
    /// `0x11`=T, `0x0F`=R, `0x2C`=Slash.
    public static let defaults = Hotkeys(
      query: Hotkey(keyCode: 0x03, modifiers: [.command, .control, .shift]),
      setupToggle: Hotkey(keyCode: 0x01, modifiers: [.command, .control, .shift]),
      monitorToggle: Hotkey(keyCode: 0x2E, modifiers: [.command, .control, .shift]),
      captureTarget: Hotkey(keyCode: 0x11, modifiers: [.command, .control, .shift]),
      repeatLast: Hotkey(keyCode: 0x0F, modifiers: [.command, .control, .shift]),
      silence: Hotkey(keyCode: 0x2C, modifiers: [.command, .control, .shift])
    )
  }

  /// A single key/modifier combo. Deliberately NOT `Carbon.HIToolbox`'s
  /// `EventHotKeyID`/key-code enum — `AboutFaceCore` must not import Carbon
  /// (it is the platform-independent core; only `App/`'s `HotkeyCenter` may
  /// touch Carbon), so this is a plain, `Codable`, testable value type that
  /// `HotkeyCenter` translates 1:1 into a real registration.
  public struct Hotkey: Codable, Sendable, Equatable {
    /// AppKit/Carbon virtual key code — identical numbering to `NSEvent
    /// .keyCode` and Carbon's `kVK_*` constants (e.g. `kVK_ANSI_F == 0x03`).
    /// Stored as a raw integer rather than an enum so `Config` never needs
    /// to know the full keyboard layout, and so a hand-edited `config.json`
    /// can express any key without a matching Swift case existing for it.
    public var keyCode: UInt32
    public var modifiers: Set<Modifier>

    public init(keyCode: UInt32, modifiers: Set<Modifier>) {
      self.keyCode = keyCode
      self.modifiers = modifiers
    }

    /// §8 hard rules, validated independent of Carbon so both `HotkeyCenter`
    /// (App/) and this package's own tests can check a combo before ever
    /// touching `RegisterEventHotKey`:
    ///
    /// - **"No global hotkey may include Option"** (§8: "Every VoiceOver
    ///   command includes Option... Excluding Option eliminates the whole
    ///   VoiceOver collision surface in one stroke"). This is the spec's own
    ///   hard MUST — CLAUDE.md repeats it verbatim as non-negotiable.
    /// - **No modifier-less combo.** Not spec text verbatim, but the
    ///   necessary consequence of §8's own worked example: every one of the
    ///   six defaults is a bare letter behind ⌘⌃⇧, precisely because a
    ///   GLOBAL hotkey with zero modifiers would steal that key from every
    ///   other app system-wide (typing a plain "F" or "/" anywhere could
    ///   never reach its intended field again) — the same "avoid stealing
    ///   ordinary input" reasoning §8 already applies to Option, just
    ///   generalized to "at least one modifier, always."
    public func validate() -> HotkeyValidationError? {
      if modifiers.contains(.option) { return .containsOption }
      if modifiers.isEmpty { return .noModifiers }
      return nil
    }

    public var isValid: Bool { validate() == nil }
  }

  /// `Hotkey.validate()`'s result type — a SIBLING of `Hotkey` (not nested
  /// inside it) because SwiftLint's `nesting` rule caps nesting at one
  /// level below `Config` (matching the `Config.Audio`/`Config
  /// .AudioPositional` precedent `Config+Audio.swift`'s own doc comment
  /// explains); `Config.Hotkey.ValidationError` would be two levels deep.
  public enum HotkeyValidationError: Sendable, Equatable {
    /// §8: "no global hotkey may include Option."
    case containsOption
    /// A hotkey with no modifiers would capture the bare key globally.
    case noModifiers
  }

  /// A modifier key `Hotkey.modifiers` may include. `.option` exists in this
  /// enum (rather than being omitted outright) specifically so
  /// `Hotkey.validate()` can name it in a rejected combo — see that method's
  /// doc comment.
  public enum Modifier: String, Codable, Sendable, Equatable, CaseIterable {
    case command
    case control
    case shift
    case option
  }

  /// Identifies one of §8's six global actions, independent of whatever
  /// `Hotkey` is currently bound to it — the key `HotkeyCenter` (App/) uses
  /// to route a fired `EventHotKeyID` back to a `PipelineModel` call, and
  /// what `Hotkeys.invalidAssignments()`/tests key their results by.
  public enum HotkeyAction: String, Codable, Sendable, Equatable, CaseIterable {
    case query
    case setupToggle
    case monitorToggle
    case captureTarget
    case repeatLast
    case silence
  }
}

extension Config.Hotkeys {
  /// All six `(action, hotkey)` pairs, in the same order §8's table lists
  /// them. The single place that iteration order is defined — used by
  /// `HotkeyCenter.updateRegistrations` (App/) to register every binding
  /// with one loop, and by this package's own tests to check every default
  /// against `Hotkey.validate()` without hand-listing the six fields twice.
  public var all: [(action: Config.HotkeyAction, hotkey: Config.Hotkey)] {
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on) trailing_comma
    // rule forbids one. Format wins (see SignalFormatter.swift for the same
    // disagreement noted elsewhere in this codebase).
    // swiftlint:disable trailing_comma
    [
      (.query, query),
      (.setupToggle, setupToggle),
      (.monitorToggle, monitorToggle),
      (.captureTarget, captureTarget),
      (.repeatLast, repeatLast),
      (.silence, silence),
    ]
    // swiftlint:enable trailing_comma
  }

  /// Every action whose bound `Hotkey` fails `Hotkey.validate()` (§8 hard
  /// rules), keyed by action. Empty for a fully legal set — `Hotkeys
  /// .defaults` MUST always produce an empty result (see
  /// `ConfigHotkeysTests`); a hand-edited `config.json` might not, which is
  /// exactly what `HotkeyCenter.updateRegistrations` uses this for: skip
  /// registering anything that shows up here rather than ever calling
  /// `RegisterEventHotKey` with an Option-inclusive or modifier-less combo.
  public func invalidAssignments() -> [Config.HotkeyAction: Config.HotkeyValidationError] {
    var result: [Config.HotkeyAction: Config.HotkeyValidationError] = [:]
    for (action, hotkey) in all {
      if let error = hotkey.validate() {
        result[action] = error
      }
    }
    return result
  }
}
