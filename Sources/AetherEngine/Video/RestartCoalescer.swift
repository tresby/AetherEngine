import Foundation

/// Coalesces a burst of producer-restart requests into at most the
/// in-flight restart plus one final restart at the settled target.
///
/// Rapid seeks on the loopback-HLS path fire one out-of-range segment
/// request (hence one restart) per intermediate scrub position. Running
/// every one serially through `HLSVideoEngine.performRestart` (each up to
/// a 5 s `waitForFinish` plus a network demuxer seek) wedged the pipeline
/// and, when a `waitForFinish` timed out, left the abandoned old producer
/// reading the shared demuxer (stealing the first post-seek packet, so the
/// survivor landed a GOP late with a wrong shift). Collapsing the burst to
/// the latest target removes both failure modes (AetherEngine#35).
///
/// Not thread-safe on its own; `HLSVideoEngine` mutates it only under
/// `restartLock`.
struct RestartCoalescer {
    private var inFlight = false
    private var pending: Int?

    /// Register a restart request for `idx`.
    /// - Returns: `true` when the caller should become the in-flight
    ///   restart worker (run `performRestart` now). `false` when a restart
    ///   is already running and this request was coalesced; the in-flight
    ///   worker will pick the latest target up via `next(justRan:)`.
    mutating func begin(_ idx: Int) -> Bool {
        if inFlight {
            pending = idx
            return false
        }
        inFlight = true
        return true
    }

    /// Called by the in-flight worker after each `performRestart` returns.
    /// - Returns: the next target to restart to, or `nil` when the burst
    ///   has settled (clears the in-flight flag).
    mutating func next(justRan idx: Int) -> Int? {
        if let p = pending, p != idx {
            pending = nil
            return p
        }
        pending = nil
        inFlight = false
        return nil
    }
}
