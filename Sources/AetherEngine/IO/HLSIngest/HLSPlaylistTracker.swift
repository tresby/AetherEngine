import Foundation

/// Pure cursor over successive refreshes of a live media playlist.
/// Feed it each freshly parsed playlist; it returns the segments to fetch,
/// in order, exactly once each. Handles the three live realities:
/// initial join (start near the live edge), normal forward growth, and the
/// provider window sliding past our cursor (rejoin at the edge, flagged as
/// a discontinuity so downstream timestamp rebase has a deterministic cue).
/// Policy notes: `edgeOffset` is expected >= 1 (0 would skip the entire
/// current window and only pick up segments on the next refresh); a rejoin
/// after a window slide resets `stallCount`; a playlist that SHRINKS
/// (spec-violating server) is indistinguishable from a stall and counts as
/// one, which is the desired pressure toward the stall budget.
struct HLSPlaylistTracker {
    /// How many segments behind the live edge to start (HLS convention: 3).
    private let edgeOffset: Int
    /// Next media-sequence number we have NOT yet returned. nil until primed.
    private(set) var nextSequence: Int?
    /// Consecutive refreshes that produced no new segment.
    private(set) var stallCount = 0

    init(edgeOffset: Int = 3) {
        self.edgeOffset = edgeOffset
    }

    mutating func newSegments(in playlist: HLSMediaPlaylist) -> [HLSMediaSegment] {
        let windowStart = playlist.mediaSequence
        let windowEnd = playlist.mediaSequence + playlist.segments.count // exclusive

        func segments(from sequence: Int, markFirstDiscontinuity: Bool) -> [HLSMediaSegment] {
            let startIndex = sequence - windowStart
            guard startIndex < playlist.segments.count else { return [] }
            var result = Array(playlist.segments[max(0, startIndex)...])
            if markFirstDiscontinuity, !result.isEmpty {
                let first = result[0]
                result[0] = HLSMediaSegment(
                    uri: first.uri, duration: first.duration, discontinuityBefore: true
                )
            }
            return result
        }

        guard let cursor = nextSequence else {
            // Initial join: live edge minus edgeOffset, clamped to the window.
            let start = max(windowStart, windowEnd - edgeOffset)
            nextSequence = windowEnd
            return segments(from: start, markFirstDiscontinuity: false)
        }

        if cursor < windowStart {
            // Window slid past us: rejoin near the edge, mark the seam.
            let start = max(windowStart, windowEnd - edgeOffset)
            nextSequence = windowEnd
            stallCount = 0
            return segments(from: start, markFirstDiscontinuity: true)
        }

        let fresh = segments(from: cursor, markFirstDiscontinuity: false)
        if fresh.isEmpty {
            stallCount += 1
        } else {
            stallCount = 0
            nextSequence = windowEnd
        }
        return fresh
    }
}
