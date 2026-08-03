import Foundation
import Testing

@testable import AboutFaceCore

/// §8: "no global hotkey may include Option" (hard rule, repeated verbatim
/// in CLAUDE.md) plus the modifier-less rejection `Config.Hotkey.validate()`
/// adds on top (see that method's doc comment) — and §8's default table,
/// "⌘⌃⇧" + F/S/M/T/R/slash.
struct ConfigHotkeysTests {

  // MARK: - Defaults compliance

  @Test("every §8 default hotkey is valid — no Option, at least one modifier")
  func defaultsAreAllValid() {
    let invalid = Config.Hotkeys.defaults.invalidAssignments()
    #expect(invalid.isEmpty)
  }

  @Test("the six defaults match §8's table: ⌘⌃⇧ + F/S/M/T/R/slash")
  func defaultsMatchSpecTable() {
    let defaults = Config.Hotkeys.defaults
    let allModifiers: Set<Config.Modifier> = [.command, .control, .shift]

    #expect(defaults.query.keyCode == 0x03)  // F
    #expect(defaults.setupToggle.keyCode == 0x01)  // S
    #expect(defaults.monitorToggle.keyCode == 0x2E)  // M
    #expect(defaults.captureTarget.keyCode == 0x11)  // T
    #expect(defaults.repeatLast.keyCode == 0x0F)  // R
    #expect(defaults.silence.keyCode == 0x2C)  // /

    for (_, hotkey) in defaults.all {
      #expect(hotkey.modifiers == allModifiers)
    }
  }

  @Test("Hotkeys.all enumerates all six actions, in §8's table order")
  func allEnumeratesEverySixAction() {
    let actions = Config.Hotkeys.defaults.all.map(\.action)
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on) trailing_comma
    // rule forbids one. Format wins (see LexiconTests.swift for the same
    // disagreement noted elsewhere in this codebase).
    // swiftlint:disable trailing_comma
    #expect(
      actions == [
        .query, .setupToggle, .monitorToggle, .captureTarget, .repeatLast, .silence,
      ])
    // swiftlint:enable trailing_comma
  }

  // MARK: - Validator, both directions

  @Test("a combo with Option is rejected regardless of other modifiers")
  func rejectsOption() {
    let withOption = Config.Hotkey(keyCode: 0x03, modifiers: [.command, .option])
    #expect(withOption.validate() == .containsOption)
    #expect(!withOption.isValid)

    let optionAlone = Config.Hotkey(keyCode: 0x03, modifiers: [.option])
    #expect(optionAlone.validate() == .containsOption)
  }

  @Test("a combo with no modifiers at all is rejected")
  func rejectsModifierless() {
    let bare = Config.Hotkey(keyCode: 0x03, modifiers: [])
    #expect(bare.validate() == .noModifiers)
    #expect(!bare.isValid)
  }

  @Test("Option takes priority over the modifier-less check when somehow both would apply")
  func optionCheckedBeforeEmptiness() {
    // Not reachable with a real combo (Option present means modifiers is
    // non-empty), but pins the documented check ORDER regardless, so a
    // future refactor of `validate()` can't silently reorder the two rules.
    let withOption = Config.Hotkey(keyCode: 0x00, modifiers: [.option])
    #expect(withOption.validate() == .containsOption)
  }

  @Test("a legal combo (Command+Control+Shift, no Option) validates clean")
  func acceptsLegalCombo() {
    let legal = Config.Hotkey(keyCode: 0x03, modifiers: [.command, .control, .shift])
    #expect(legal.validate() == nil)
    #expect(legal.isValid)
  }

  @Test("a single non-Option modifier is sufficient to pass validation")
  func singleModifierIsValid() {
    let single = Config.Hotkey(keyCode: 0x03, modifiers: [.command])
    #expect(single.isValid)
  }

  @Test("invalidAssignments() reports every offending action, keyed correctly")
  func invalidAssignmentsReportsByAction() {
    var hotkeys = Config.Hotkeys.defaults
    hotkeys.query.modifiers = [.command, .option]
    hotkeys.silence.modifiers = []

    let invalid = hotkeys.invalidAssignments()
    #expect(invalid.count == 2)
    #expect(invalid[.query] == .containsOption)
    #expect(invalid[.silence] == .noModifiers)
    #expect(invalid[.setupToggle] == nil)
  }

  // MARK: - Codable round-trip (§11: Config is a versioned Codable struct)

  @Test("Config.Hotkeys round-trips through JSON unchanged")
  func codableRoundTrip() throws {
    let original = Config.Hotkeys.defaults
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.Hotkeys.self, from: data)
    #expect(decoded == original)
  }

  @Test("Config.defaults carries the §8 default hotkeys")
  func configDefaultsIncludesHotkeys() {
    #expect(Config.defaults.hotkeys == Config.Hotkeys.defaults)
  }
}
