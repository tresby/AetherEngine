import Testing
import Libavutil
import Libavfilter
@testable import AetherEngine

/// Regression for interlaced MPEG-2 / VC-1 / MPEG-4 (DVD rips) playing at
/// half speed (and freezing on resume).
///
/// bwdif/yadif halve the filter's output `time_base` and scale frame PTS
/// by `pts_multiplier` (=2) even in `send_frame` mode. If the decoder
/// reads the filtered frame's PTS with the *stream* time_base (un-halved),
/// every presentation timestamp lands at 2x its real wall-clock time:
/// the renderer paces frames at half rate and a resume seek puts frames
/// in the far future, freezing the picture. `DeinterlaceFilter.pull`
/// must rescale the pulled PTS from the buffersink time_base back into the
/// stream time_base so downstream `emit()` (which uses the stream
/// time_base) sees real timestamps.
struct DeinterlaceTimebaseTests {

    /// Allocate a small interlaced YUV420P frame with the given PTS.
    private func makeFrame(pts: Int64) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    @Test("Deinterlaced frame PTS stays on the stream time_base (no 2x drift)")
    func deinterlacedPTSMatchesStreamTimebase() {
        // 1 tick == 1/30 s. After the fix, a frame whose source PTS is N
        // must come out of the filter with a PTS that, read on THIS
        // time_base, is still N (i.e. N/30 s) — not 2N.
        let streamTB = AVRational(num: 1, den: 30)
        let tbSeconds = Double(streamTB.num) / Double(streamTB.den)

        let filter = DeinterlaceFilter()
        defer { filter.teardown() }

        // Feed a run of frames with monotonically increasing PTS.
        let inputPTS: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7]
        var outSeconds: [Double] = []

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        for pts in inputPTS {
            let f = makeFrame(pts: pts)
            // ensureGraph is idempotent once built; mirrors the decoder.
            let built = filter.ensureGraph(frame: f, timeBase: streamTB)
            #expect(built, "bwdif/yadif must be available in the linked FFmpeg build")
            guard built else { var ff: UnsafeMutablePointer<AVFrame>? = f; av_frame_free(&ff); return }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    // Interpret the pulled PTS the way emit() does: with the
                    // STREAM time_base. The fix makes pull() rescale into it.
                    outSeconds.append(Double(out.pointee.pts) * tbSeconds)
                }
                av_frame_unref(out)
            }
        }

        #expect(!outSeconds.isEmpty, "filter produced no frames")

        // The newest source frame is at 7/30 s. Pre-fix, outputs run to
        // ~14/30 s (2x). The deinterlacer holds one frame of lookahead, so
        // the latest output trails the latest input by one frame at most.
        let maxInput = Double(inputPTS.max()!) * tbSeconds
        for s in outSeconds {
            #expect(s <= maxInput + tbSeconds * 0.5,
                    "output PTS \(s)s exceeds source range (max \(maxInput)s) — time_base doubled")
        }

        // Consecutive outputs must be one frame apart (1/30 s), not two.
        let sorted = outSeconds.sorted()
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(abs(delta - tbSeconds) < tbSeconds * 0.25,
                        "frame spacing \(delta)s is not ~\(tbSeconds)s (time_base doubled)")
            }
        }
    }
}
