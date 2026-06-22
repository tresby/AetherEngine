import Foundation

/// Collapses burst seek restarts to in-flight + one pending (AetherEngine#35). Rapid scrubs on loopback-HLS fired one `performRestart` per position (up to 5s `waitForFinish` + demuxer seek each); timeout left the abandoned producer reading the shared demuxer, stealing the first post-seek packet. Not thread-safe; HLSVideoEngine mutates under `restartLock`.
struct RestartCoalescer {
    private var inFlight = false
    private var pending: Int?

    /// Returns `true` if the caller should become the in-flight worker; `false` if coalesced (in-flight worker will pick it up via `next(justRan:)`).
    mutating func begin(_ idx: Int) -> Bool {
        if inFlight {
            pending = idx
            return false
        }
        inFlight = true
        return true
    }

    /// Returns next pending target, or `nil` when the burst has settled (clears in-flight flag).
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
