/// §5's Setup/Monitor mode distinction, as seen by `FeedbackRouter`. Query
/// mode (§5.3) is a one-shot burst-then-summary flow triggered by a hotkey,
/// not a sustained `ingest(_:at:)` stream — it is not modeled as a
/// `FeedbackRouter` mode this phase; it consumes `Lexicon`'s **state**
/// register directly (see `Lexicon.swift`) from whatever burst-analysis
/// mechanism Phase 4/5 adds.
///
/// This is also the N-frame suppression "rate hint" (§7.2): the two shipped
/// modes each name a fixed analysis rate (§5.1: Setup at 30Hz; §5.2: Monitor
/// at 5Hz), so mode selects `FeedbackConfig.nFrameSetup`/`nFrameMonitor`
/// directly rather than `FeedbackRouter` needing a separate raw-Hz input.
public enum FeedbackMode: String, Codable, Sendable, Equatable, CaseIterable {
  case setup
  case monitor
}
