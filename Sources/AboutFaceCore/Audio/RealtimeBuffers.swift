// Wait-free cross-thread handoff primitives for `AudioRenderer` (§3.1: "the
// audio render callback may not allocate, lock, or make blocking Swift
// runtime calls"). Both types below are allocated exactly once (at
// `RenderState.init`), touched only via atomic operations on plain integer
// state, and never allocate, lock, or block on either the writer side
// (`update`/`play`/`setSilenced`, called from `AudioRenderer`'s
// actor-isolated methods) or the reader side (the `AVAudioSourceNode`
// render block, called on CoreAudio's real-time thread).
//
// `Synchronization.Atomic` is used rather than a third-party atomics
// package deliberately — it ships in the Swift standard library (available
// since this package already requires macOS 15 / Swift 6), so reaching for
// it does not violate `AboutFaceCore`'s "stays dependency-free" rule in
// `Package.swift` any more than `Foundation` or `CoreMedia` do.
import Synchronization

// MARK: - Triple buffer (continuous parameters)

/// Wait-free single-producer/single-consumer triple buffer, handing the
/// latest published value of `T` from one writer thread to one reader
/// thread. This is the classic "triple buffering as a concurrency
/// primitive" technique (three fixed buffers, ownership of all three fully
/// determined at all times by the writer's private index, the reader's
/// private index, and one shared atomic slot holding the third): every
/// `write`/`readIfNew` call is exactly one atomic exchange plus O(1) pointer
/// bookkeeping. There is no CAS retry loop and no spin — both sides make
/// bounded, constant progress every call, which is the actual real-time
/// requirement (stronger than merely "lock-free": this is wait-free).
///
/// Invariant maintained at all times: `{writeIndex, readIndex, shared index}`
/// is always a permutation of `{0, 1, 2}`. The writer only ever writes to
/// `storage[writeIndex]`, which by the invariant is neither the buffer the
/// reader currently holds nor the buffer currently published in the shared
/// slot — so the writer can never race the reader, and vice versa.
final class TripleBuffer<T>: @unchecked Sendable where T: Sendable {
  private static var newDataFlag: UInt8 { 0b100 }
  private static var indexMask: UInt8 { 0b011 }

  private let storage: UnsafeMutablePointer<T>
  private let shared: Atomic<UInt8>

  // Writer-private and reader-private indices: each is touched from exactly
  // one thread (the actor-isolated writer methods, or the render callback,
  // respectively), so neither needs synchronization of its own.
  private var writeIndex: UInt8 = 0
  private var readIndex: UInt8 = 1

  /// - Parameter initial: written into all three buffer slots up front, so
  ///   a reader that calls `readIfNew()` before the first `write()` safely
  ///   gets `nil` (nothing new published yet) rather than uninitialized
  ///   memory — callers should seed their own cached "current" value with
  ///   this same `initial` and only overwrite it when `readIfNew()` returns
  ///   non-nil.
  init(initial: T) {
    storage = .allocate(capacity: 3)
    storage.initialize(repeating: initial, count: 3)
    // Shared slot starts at index 2 (the one buffer neither writeIndex=0
    // nor readIndex=1 owns), with the "new data" flag clear.
    shared = Atomic<UInt8>(2)
  }

  deinit {
    storage.deinitialize(count: 3)
    storage.deallocate()
  }

  /// Producer side. Call only from the single writer thread.
  func write(_ value: T) {
    storage[Int(writeIndex)] = value
    let published = writeIndex | Self.newDataFlag
    // Release: the write to `storage[writeIndex]` above must be visible to
    // whichever thread's subsequent acquiring load/exchange observes this
    // published index.
    let previous = shared.exchange(published, ordering: .acquiringAndReleasing)
    writeIndex = previous & Self.indexMask
  }

  /// Consumer side. Call only from the single reader thread (the render
  /// callback). Returns the most recently published value, or `nil` if
  /// nothing new has been published since the last call — callers should
  /// keep using their previously-read value in that case.
  func readIfNew() -> T? {
    let current = shared.load(ordering: .acquiring)
    guard current & Self.newDataFlag != 0 else { return nil }
    let previous = shared.exchange(readIndex, ordering: .acquiringAndReleasing)
    readIndex = previous & Self.indexMask
    return storage[Int(readIndex)]
  }
}

// MARK: - SPSC ring buffer (discrete events)

/// Wait-free single-producer/single-consumer ring buffer of raw bytes, used
/// to hand `AudioEvent`s (encoded via `EarconKind.rawByte`) from
/// `AudioRenderer.play(_:)` to the render callback without dropping events
/// the way an "always keep only the latest" triple buffer would — earcons
/// are discrete and each one matters, unlike the continuous position
/// snapshot where only the latest value is ever meaningful.
///
/// Producer touches only `tail` (and reads `head` to check for space);
/// consumer touches only `head` (and reads `tail` to check for data) — each
/// side owns exactly one index, so no locking is needed for correctness,
/// only the acquire/release pairing that makes the buffer contents visible
/// across the handoff.
final class RingBuffer: @unchecked Sendable {
  private let capacity: Int
  private let storage: UnsafeMutablePointer<UInt8>
  private let head = Atomic<Int>(0)
  private let tail = Atomic<Int>(0)

  init(capacity: Int) {
    self.capacity = capacity
    storage = .allocate(capacity: capacity)
  }

  deinit {
    storage.deallocate()
  }

  /// Producer side. Drops the event if the buffer is full (should not
  /// happen in practice: events are gated by dwell/hysteresis upstream and
  /// the render thread drains this every buffer, i.e. at least every
  /// `Config.AudioEngine.bufferFrameSize` / `sampleRate` seconds).
  func push(_ value: UInt8) {
    let currentTail = tail.load(ordering: .relaxed)
    let nextTail = (currentTail + 1) % capacity
    guard nextTail != head.load(ordering: .acquiring) else { return }
    storage[currentTail] = value
    tail.store(nextTail, ordering: .releasing)
  }

  /// Consumer side. Call repeatedly until `nil` to drain everything
  /// published since the last drain.
  func pop() -> UInt8? {
    let currentHead = head.load(ordering: .relaxed)
    guard currentHead != tail.load(ordering: .acquiring) else { return nil }
    let value = storage[currentHead]
    head.store((currentHead + 1) % capacity, ordering: .releasing)
    return value
  }
}
