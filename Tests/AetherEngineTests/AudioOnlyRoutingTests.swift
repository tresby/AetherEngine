import Testing
@testable import AetherEngine

@Suite("Audio-only routing decision")
struct AudioOnlyRoutingTests {

    @Test("Explicit audioOnly forces the audio path even with a video stream")
    func explicitFlagForcesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, hasVideoStream: true) == true)
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, hasVideoStream: false) == true)
    }

    @Test("No video stream routes to the audio path")
    func noVideoRoutesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, hasVideoStream: false) == true)
    }

    @Test("Video stream without the flag stays on the video path")
    func videoStaysVideo() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, hasVideoStream: true) == false)
    }
}
