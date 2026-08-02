import AboutFaceCore
import ArgumentParser
import Foundation

/// `aboutface-cli config-defaults <path>` — writes `Config.defaults` as a
/// ConfigStore-format JSON export. Exists so tuning profiles can be built
/// from the command line by patching a known-good baseline file — the debug
/// panel's Export button is the GUI path to the same format, but a blind
/// maintainer scripting experiment profiles (or CI generating them)
/// shouldn't need the app running. See Fixtures/tuning-profiles/README.md
/// for the experiment workflow this serves.
struct ConfigDefaults: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config-defaults",
    abstract: "Write Config.defaults as a JSON tuning-profile file."
  )

  @Argument(help: "Output path for the JSON profile.")
  var path: String

  func run() throws {
    try ConfigStore.export(.defaults, to: URL(fileURLWithPath: path))
    print("Wrote defaults to \(path).")
  }
}
