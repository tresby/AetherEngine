import Testing
@testable import AetherEngine

// #74: at head-of-stream the producer's audio gate dropped every audio packet that arrived before the
// first video packet. On wide-interleave sources (audio muxed ~1 s ahead of video in file order) that
// discarded the whole first second of real audio, so AVPlayer pulled the survivors forward into a
// constant ~1 s desync. The fix buffers pre-gate audio (bounded) and replays it in DTS order once the
// video gate opens. These cover the buffering DECISION: only head-of-stream, only while the gate waits,
// only audio, only under the byte cap. Restart/seek producers (restartTargetVideoDts != min) must keep
// the old drop, where the post-gate shift-snap already aligns audio.
@Suite("HLSSegmentProducer pre-gate audio buffering decision")
struct PregateAudioBufferTests {

    private let cap = 8 * 1024 * 1024

    @Test("A non-audio packet is never buffered")
    func nonAudioNotBuffered() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: false, audioWaitForVideo: true, isHeadOfStream: true,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("Audio is not buffered once the video gate has opened")
    func notBufferedAfterGateOpen() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: false, isHeadOfStream: true,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("Restart/seek producers (not head-of-stream) keep the old drop, never buffer")
    func notBufferedOnRestart() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: false,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("Head-of-stream pre-gate audio under the cap is buffered")
    func bufferedAtHeadOfStream() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true,
            bufferedBytes: 64 * 1024, packetSize: 1024, capBytes: cap) == true)
    }

    @Test("Buffering is allowed exactly up to the cap boundary")
    func capBoundaryInclusive() {
        // bufferedBytes + packetSize == cap: still fits.
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true,
            bufferedBytes: cap - 1024, packetSize: 1024, capBytes: cap) == true)
    }

    @Test("Over the cap falls back to the old drop (not buffered)")
    func overCapNotBuffered() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true,
            bufferedBytes: cap - 1024, packetSize: 1025, capBytes: cap) == false)
    }
}
