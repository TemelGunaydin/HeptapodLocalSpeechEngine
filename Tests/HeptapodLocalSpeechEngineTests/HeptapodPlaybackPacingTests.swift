import Foundation
import Testing
import HeptapodLocalSpeechEngine
@testable import HeptapodSpeechSwiftAdapters

struct HeptapodPlaybackPacingTests {
    @Test(arguments: [16_000, 24_000, 48_000])
    func schedulingChunksPreserveEveryPCMByte(sampleRate: Int) {
        let pcm = Data((0..<(sampleRate * 2 + 14)).map { UInt8($0 % 251) })
        let speech = HeptapodSynthesizedSpeech(pcm16: pcm, sampleRate: sampleRate, languageCode: "tr")
        let chunks = Array(HeptapodSpeechSwiftAudioSamples.playbackChunks(from: speech))
        var reassembled = Data()
        for chunk in chunks {
            #expect(chunk.pcm16.count <= sampleRate / 5 * 2)
            #expect(chunk.pcm16.count % 2 == 0)
            #expect(chunk.sampleRate == sampleRate)
            #expect(chunk.languageCode == "tr")
            reassembled.append(chunk.pcm16)
        }
        #expect(chunks.count == 6)
        #expect(reassembled == pcm)
    }

    @Test
    func longAudioAcceleratesEvenWithOnePlaybackSegment() {
        var pacing = HeptapodPlaybackPacing()
        pacing.setBacklog(1, at: 0)
        pacing.enqueueAudio(duration: 12, at: 0)
        for second in 1...4 { pacing.setBacklog(1, at: Double(second)) }

        #expect(abs(pacing.rate - 1.15) < 0.0001)
        #expect(pacing.state.pendingAudioDuration == 12)
    }

    @Test
    func shortAudioKeepsNaturalPaceEvenWithMultipleSegments() {
        var pacing = HeptapodPlaybackPacing()
        pacing.enqueueAudio(duration: 1, at: 0)
        pacing.setBacklog(2, at: 1)
        pacing.setBacklog(2, at: 2)

        #expect(pacing.rate == 1)
    }

    @Test(arguments: [Float(1), 1.15, 1.35])
    func honorsConfiguredCeiling(maximumRate: Float) {
        var pacing = HeptapodPlaybackPacing(maximumRate: maximumRate)
        pacing.enqueueAudio(duration: 40, at: 0)
        for second in 1...10 {
            pacing.setBacklog(2, at: Double(second))
            #expect(pacing.rate <= maximumRate)
        }
        #expect(abs(pacing.rate - maximumRate) < 0.0001)
    }

    @Test
    func rateSlewDependsOnTimeNotCallbackCount() {
        var frequent = HeptapodPlaybackPacing(maximumRate: 1.5)
        var sparse = frequent
        frequent.enqueueAudio(duration: 40, at: 0)
        sparse.enqueueAudio(duration: 40, at: 0)
        for tick in 1...20 { frequent.setBacklog(2, at: Double(tick) / 10) }
        for second in 1...2 { sparse.setBacklog(2, at: Double(second)) }

        #expect(abs(frequent.rate - 1.1) < 0.0001)
        #expect(abs(frequent.rate - sparse.rate) < 0.0001)
        let previousRate = frequent.rate
        frequent.setBacklog(2, at: 1)
        #expect(frequent.rate == previousRate)
    }

    @Test
    func completedAudioDrainsAccountingAndRestoresBaseRate() {
        var pacing = HeptapodPlaybackPacing()
        pacing.setBacklog(2, at: 0)
        pacing.enqueueAudio(duration: 8, at: 0)
        pacing.completeAudio(duration: 1, at: 1)
        pacing.completeAudio(duration: 2, at: 2)
        #expect(pacing.state.pendingAudioDuration == 5)
        #expect(pacing.state.completedAudioDuration == 3)
        #expect(pacing.rate > 1)
        pacing.completeAudio(duration: 5, at: 3)
        pacing.setBacklog(0, at: 3)

        #expect(pacing.state.pendingAudioDuration == 0)
        #expect(pacing.state.completedAudioDuration == 8)
        #expect(pacing.state.peakPendingAudioDuration == 8)
        #expect(pacing.rate == 1)
        #expect(pacing.state.peakPlaybackRate > 1)
    }

    @Test
    func invalidDurationsAndRatesDoNotPoisonPlayback() {
        var pacing = HeptapodPlaybackPacing(baseRate: .nan, maximumRate: .infinity)
        for duration in [Double.nan, .infinity, -1, 0] {
            pacing.enqueueAudio(duration: duration, at: 0)
            pacing.completeAudio(duration: duration, at: 1)
        }
        #expect(pacing.state.pendingAudioDuration == 0)
        #expect(pacing.state.completedAudioDuration == 0)
        #expect(pacing.rate == 1)
        #expect(pacing.isTrackingAudio == false)
    }

    @Test
    func resetClearsPendingAudioAndPeaks() {
        var pacing = HeptapodPlaybackPacing(maximumRate: 1.35)
        pacing.enqueueAudio(duration: 20, at: 0)
        pacing.setBacklog(2, at: 1)
        pacing.reset()

        #expect(pacing.state.pendingAudioDuration == 0)
        #expect(pacing.state.peakPendingAudioDuration == 0)
        #expect(pacing.state.completedAudioDuration == 0)
        #expect(pacing.state.peakPlaybackRate == 1)
        #expect(pacing.rate == 1)
        #expect(pacing.maximumRate == 1.35)
        #expect(pacing.isTrackingAudio == false)
    }

    @Test
    func playbackCancellationClearsTrackedAudioWithoutStartingHardware() async throws {
        let sink = HeptapodAVAudioPlaybackSink()
        await sink.setPlaybackBacklog(segmentCount: 2)
        await sink.enqueuePlaybackAudio(duration: 12)
        let before = try #require(await sink.playbackAudioState())
        #expect(before.pendingAudioDuration == 12)
        await sink.cancelPlayback()
        #expect(await sink.playbackAudioState() == nil)
    }
}
