import AudioCommon
import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodSpeechSwiftAudioSamples {
    public static func floatSamples(from chunk: HeptapodAudioChunk, targetSampleRate: Int) -> [Float] {
        let samples = floatSamples(fromPCM16: chunk.pcm16)
        guard chunk.sampleRate != targetSampleRate else {
            return samples
        }
        return AudioFileLoader.resample(samples, from: chunk.sampleRate, to: targetSampleRate)
    }

    public static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return (0..<sampleCount).map { index in
                Float(Int16(littleEndian: int16Buffer[index])) / 32768.0
            }
        }
    }

    public static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767.0).littleEndian
            var mutableValue = value
            data.append(Data(bytes: &mutableValue, count: MemoryLayout<Int16>.size))
        }
        return data
    }
}
