import Testing

@testable import AboutFaceCore

/// §6.3: "Vocabulary is a small fixed closed set... Define the full lexicon
/// in one file, `Lexicon.swift`, and do not generate phrases dynamically."
struct LexiconTests {

  @Test("SpeechRendering's speak(_:) can only ever receive a Lexicon.Phrase, never a raw String")
  func closedVocabularyIsEnforcedByTheTypeSystem() {
    // `SpeechRendering.speak(_ phrase: Lexicon.Phrase)` and
    // `Lexicon.Phrase.init` being `private` to `Lexicon.swift` together
    // mean neither of these compiles — this is a compile-time guarantee,
    // not a runtime check, so there is nothing to execute; the proof is
    // that the file containing this test builds at all with the lines
    // below commented out, and would NOT build with either uncommented:
    //
    //   let renderer: any SpeechRendering = MockSpeechRenderer()
    //   await renderer.speak("Left.")                          // ❌ 'String' is not 'Lexicon.Phrase'
    //   await renderer.speak(Lexicon.Phrase(text: "made up"))   // ❌ 'Phrase.init' is private
    //
    // What IS checked at runtime below is that the closed set itself is
    // real: non-empty, fixed text, every phrase constructible only via the
    // static members `Lexicon` itself defines.
    //
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Format wins (see
    // FeedbackRouter+Announcements.swift for the same disagreement).
    // swiftlint:disable trailing_comma
    let instructions: [Lexicon.Phrase] = [
      Lexicon.Instruction.left,
      Lexicon.Instruction.right,
      Lexicon.Instruction.up,
      Lexicon.Instruction.down,
      Lexicon.Instruction.closer,
      Lexicon.Instruction.back,
      Lexicon.Instruction.centered,
      Lexicon.Instruction.noFace,
      Lexicon.Instruction.noSignal,
      Lexicon.Instruction.tooDark,
      Lexicon.Instruction.lookAtCamera,
      Lexicon.Instruction.level,
      Lexicon.Instruction.recovered,
    ]
    let states: [Lexicon.Phrase] = [
      Lexicon.State.left,
      Lexicon.State.right,
      Lexicon.State.high,
      Lexicon.State.low,
      Lexicon.State.close,
      Lexicon.State.far,
      Lexicon.State.centered,
      Lexicon.State.noFace,
      Lexicon.State.noSignal,
      Lexicon.State.tooDark,
      Lexicon.State.gazeOff,
      Lexicon.State.headTilted,
    ]
    // swiftlint:enable trailing_comma

    for phrase in instructions + states {
      #expect(!phrase.text.isEmpty)
    }
  }

  @Test("the §12.2/§16.4 reminder phrase is the maintainer's exact decided wording")
  func reminderPhraseMatchesDecidedWording() {
    #expect(Lexicon.Reminder.cameraInUseMonitorOff.text == "Camera in use. Monitor is off.")
  }

  @Test("the §8 hotkey/button Confirmation register is a real closed set, non-empty fixed text")
  func confirmationRegisterIsClosed() {
    // swiftlint:disable trailing_comma
    let confirmations: [Lexicon.Phrase] = [
      Lexicon.Confirmation.monitorOn,
      Lexicon.Confirmation.monitorOff,
      Lexicon.Confirmation.monitorFailedToStart,
      Lexicon.Confirmation.silenced,
      Lexicon.Confirmation.unsilenced,
      Lexicon.Confirmation.targetCaptured,
      Lexicon.Confirmation.noFaceToCapture,
    ]
    // swiftlint:enable trailing_comma
    for phrase in confirmations {
      #expect(!phrase.text.isEmpty)
    }
  }

  @Test("Monitor on/off confirmation wording is exactly the maintainer's decided phrasing")
  func monitorConfirmationWordingIsTerse() {
    // Task brief, verbatim: "'Monitor on.' / 'Monitor off.' are already
    // right — do not embellish."
    #expect(Lexicon.Confirmation.monitorOn.text == "Monitor on.")
    #expect(Lexicon.Confirmation.monitorOff.text == "Monitor off.")
  }

  @Test("the spec's illustrative instruction phrases match verbatim")
  func illustrativePhrasesMatchSpecVerbatim() {
    // §6.3's own examples, verbatim: "Left." "Right." "Closer." "Back."
    // "Centered." "No face." "Back, centered." "Too dark."
    #expect(Lexicon.Instruction.left.text == "Left.")
    #expect(Lexicon.Instruction.right.text == "Right.")
    #expect(Lexicon.Instruction.closer.text == "Closer.")
    #expect(Lexicon.Instruction.back.text == "Back.")
    #expect(Lexicon.Instruction.centered.text == "Centered.")
    #expect(Lexicon.Instruction.noFace.text == "No face.")
    #expect(Lexicon.Instruction.recovered.text == "Back, centered.")
    #expect(Lexicon.Instruction.tooDark.text == "Too dark.")
  }

  @Test("two Phrase values with the same text are equal, and Phrase is Hashable")
  func phraseIsEquatableAndHashable() {
    #expect(Lexicon.Instruction.left == Lexicon.Instruction.left)
    #expect(Lexicon.Instruction.left != Lexicon.Instruction.right)
    let set: Set<Lexicon.Phrase> = [Lexicon.Instruction.left, Lexicon.Instruction.left]
    #expect(set.count == 1)
  }
}
