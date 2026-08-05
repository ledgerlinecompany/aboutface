import Testing

@testable import AboutFaceCore

/// §12.4's virtual-camera name matching. The governing principle
/// (`VirtualCameraPatterns`'s doc comment) is that over-detection is worse
/// than under-detection — telling a user their genuine camera is fake is a
/// confident, out-loud claim, where a missed detection is merely silence. So
/// these tests pin the matcher's conservatism as hard as they pin its
/// positives.
struct VirtualCameraClassifierTests {

  @Test("Known virtual cameras match, by exact device name")
  func knownNamesMatch() {
    #expect(
      VirtualCameraClassifier.match(displayName: "OBS Virtual Camera")?.pattern
        == "OBS Virtual Camera")
    #expect(VirtualCameraClassifier.match(displayName: "Snap Camera")?.pattern == "Snap Camera")
    #expect(VirtualCameraClassifier.match(displayName: "CamTwist")?.pattern == "CamTwist")
  }

  @Test("Matching is case-insensitive — device names are not reliably capitalized")
  func matchingIsCaseInsensitive() {
    #expect(VirtualCameraClassifier.match(displayName: "obs virtual camera") != nil)
    #expect(VirtualCameraClassifier.match(displayName: "SNAP CAMERA") != nil)
  }

  @Test("A pattern surrounded by other words still matches — it is a phrase, not the whole name")
  func patternWithinLongerNameMatches() {
    #expect(VirtualCameraClassifier.match(displayName: "Reincubate Camo") != nil)
    #expect(VirtualCameraClassifier.match(displayName: "OBS Virtual Camera (2)") != nil)
  }

  @Test("Punctuation and hyphens count as word boundaries, not as part of a word")
  func punctuationIsABoundary() {
    #expect(VirtualCameraClassifier.contains("Camo-Camera", wholeWord: "Camo"))
    #expect(VirtualCameraClassifier.contains("[mmhmm]", wholeWord: "mmhmm"))
  }

  /// THE test this rule exists for. A plain substring match would fire on
  /// every name below; word-boundary matching does not. Short patterns
  /// (`Camo` is four characters, `mmhmm` five) are the ones at real risk of
  /// falling inside an unrelated token, including in a localized name.
  @Test("A pattern appearing inside a longer word does NOT match")
  func substringInsideAWordDoesNotMatch() {
    #expect(VirtualCameraClassifier.match(displayName: "Camouflage Cam") == nil)
    #expect(VirtualCameraClassifier.contains("Camouflage", wholeWord: "Camo") == false)
    #expect(VirtualCameraClassifier.contains("mmhmmmm", wholeWord: "mmhmm") == false)
    #expect(VirtualCameraClassifier.contains("ManyCameras", wholeWord: "ManyCam") == false)
  }

  @Test("Ordinary physical cameras never match")
  func physicalCamerasDoNotMatch() {
    #expect(VirtualCameraClassifier.match(displayName: "FaceTime HD Camera") == nil)
    #expect(VirtualCameraClassifier.match(displayName: "Studio Display Camera") == nil)
    #expect(VirtualCameraClassifier.match(displayName: "Logitech BRIO") == nil)
    #expect(VirtualCameraClassifier.match(displayName: "Shane's iPhone Camera") == nil)
    #expect(VirtualCameraClassifier.match(displayName: "Desk View Camera") == nil)
  }

  @Test("An empty pattern never matches — a data error must not match everything")
  func emptyPatternNeverMatches() {
    #expect(VirtualCameraClassifier.contains("FaceTime HD Camera", wholeWord: "") == false)
  }

  @Test("A pattern longer than the name never matches")
  func patternLongerThanNameDoesNotMatch() {
    #expect(VirtualCameraClassifier.contains("OBS", wholeWord: "OBS Virtual Camera") == false)
  }

  @Test("Every seeded entry carries a non-empty pattern and an explanatory note")
  func seededEntriesAreWellFormed() {
    #expect(VirtualCameraPatterns.known.isEmpty == false)
    for entry in VirtualCameraPatterns.known {
      #expect(entry.pattern.isEmpty == false)
      #expect(entry.note.isEmpty == false)
    }
  }
}
