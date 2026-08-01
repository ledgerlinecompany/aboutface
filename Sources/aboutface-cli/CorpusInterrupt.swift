import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Ctrl-C safety for `record-corpus`: an in-progress take must never leave
/// a corrupt/half-written file at its target path (task brief: "writer
/// finalized or partial file removed — no corrupt leftovers").
///
/// `CorpusRecorder` writes each take directly to its final
/// `Fixtures/corpus/clips/<NN-slug>.mov` path via `AVAssetWriter`, which
/// does not produce a valid, parseable `.mov` until `finishWriting`
/// completes. So a process death mid-take always leaves, at worst, an
/// unfinished file at exactly that path — `CorpusInterruptGuard` tracks the
/// current take's URL and deletes it before the process exits, so a
/// resumed session (or a `verify-corpus` run) sees a clean "not yet
/// recorded" state rather than a broken file.
final class CorpusInterruptGuard: @unchecked Sendable {
  static let shared = CorpusInterruptGuard()

  private let lock = NSLock()
  private var currentTakeURL: URL?
  private var signalSources: [DispatchSourceSignal] = []

  private init() {}

  /// Installs SIGINT and SIGTERM handlers. Call once, near the start of
  /// `run()`. SIGTERM as well as SIGINT: process supervisors and job
  /// runners commonly stop a long-lived interactive process with SIGTERM
  /// rather than SIGINT (confirmed empirically while building this — a
  /// non-SIGINT kill of a mid-take process left exactly the half-written
  /// file this guard exists to prevent), and both are equally "the process
  /// is going away, clean up now" from this guard's point of view.
  ///
  /// Uses a dedicated (non-main) serial queue, not `.main`: this executable
  /// drives its async `run()` through `AsyncParsableCommand`'s generated
  /// entry point rather than a pumped main run loop / `dispatchMain()`, so
  /// a `DispatchSourceSignal` scheduled on `.main` would not reliably fire
  /// — GCD only services the main queue when something is actively pumping
  /// it, which nothing here does. A private serial queue is instead
  /// serviced by libdispatch's own worker threads regardless of what the
  /// main thread is doing, so the handler fires promptly either way.
  ///
  /// `signal(_, SIG_IGN)` first for each: per Apple's documented
  /// `DispatchSourceSignal` usage, if the signal's default disposition is
  /// still "terminate," the process can die before GCD gets a chance to
  /// deliver it to the handler.
  func install() {
    let queue = DispatchQueue(label: "com.ledgerlinecompany.aboutface.corpus-interrupt")
    for signalNumber in [SIGINT, SIGTERM] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [weak self] in
        self?.handleInterrupt()
      }
      source.resume()
      signalSources.append(source)
    }
  }

  /// Set to the take's target URL immediately before writing starts, and
  /// back to `nil` immediately after writing finishes (success or
  /// failure) — the window during which an interrupt must clean up.
  func setCurrentTake(_ url: URL?) {
    lock.lock()
    currentTakeURL = url
    lock.unlock()
  }

  private func handleInterrupt() {
    lock.lock()
    let url = currentTakeURL
    lock.unlock()
    if let url {
      try? FileManager.default.removeItem(at: url)
    }
    FileHandle.standardError.write(
      Data("\nInterrupted. Re-run record-corpus to resume — completed clips are kept.\n".utf8))
    exit(130)
  }
}
