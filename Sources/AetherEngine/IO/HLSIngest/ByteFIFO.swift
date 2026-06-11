import Foundation

/// Bounded blocking byte queue between the ingest's fetch loop (writer) and
/// the demux thread (reader). NSCondition-based; both sides may block, both
/// are unblocked by `finish()` (EOF) and `cancel()` (error). Storage is a
/// Data re-based with subdata on consume, never `removeFirst`
/// (the persistent-window slice-storage lesson, AetherEngine 70430de).
/// Capacity is a soft bound: a write blocks only while the queue is at or
/// above capacity, then appends its whole chunk, so storage can exceed
/// capacity by at most one chunk. Wakeups use broadcast so the queue stays
/// correct even with more than one waiter per side.
final class ByteFIFO: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var storage = Data()
    private var finished = false
    private var cancelled = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Append, blocking while the queue is at capacity.
    /// Returns false once finished or cancelled (writer should stop).
    func write(_ data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while storage.count >= capacity && !finished && !cancelled {
            condition.wait()
        }
        if finished || cancelled { return false }
        storage.append(data)
        condition.broadcast()
        return true
    }

    /// Blocking read of up to `maxLength` bytes.
    /// Returns: >0 bytes copied; 0 = EOF (finished and drained); -1 = cancelled.
    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while storage.isEmpty && !finished && !cancelled {
            condition.wait()
        }
        if cancelled { return -1 }
        if storage.isEmpty { return 0 } // finished + drained
        let n = min(maxLength, storage.count)
        storage.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n), from: 0..<n)
        // Re-base instead of removeFirst: removeFirst on a long-lived Data
        // retains the sliced-off prefix's backing storage.
        storage = storage.subdata(in: n..<storage.count)
        condition.broadcast()
        return n
    }

    /// Writer-side EOF: readers drain the remainder, then get 0.
    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Hard stop: both sides unblock, readers get -1, writers get false.
    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
