import AudioCommon
import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodSpeechSwiftAudioIO {
    public static func loadAudioChunk(
        from url: URL,
        targetSampleRate: Int = 16_000
    ) throws -> HeptapodAudioChunk {
        let samples = try AudioFileLoader.load(url: url, targetSampleRate: targetSampleRate)
        return HeptapodAudioChunk(
            pcm16: HeptapodSpeechSwiftAudioSamples.pcm16Data(from: samples),
            sampleRate: targetSampleRate
        )
    }

    public static func writeWAV(
        _ speech: HeptapodSynthesizedSpeech,
        to url: URL
    ) throws {
        let samples = HeptapodSpeechSwiftAudioSamples.floatSamples(fromPCM16: speech.pcm16)
        try WAVWriter.write(samples: samples, sampleRate: speech.sampleRate, to: url)
    }
}
