import AudioCommon
import Foundation
import HeptapodLocalSpeechEngine

public struct HeptapodAudioFileChunkSource: HeptapodAudioChunkSource {
    public let url: URL
    public let targetSampleRate: Int
    public let chunkDurationSeconds: Double
    public let interval: Duration?

    public init(
        url: URL,
        targetSampleRate: Int = 16_000,
        chunkDurationSeconds: Double = 1.0,
        interval: Duration? = nil
    ) {
        self.url = url
        self.targetSampleRate = targetSampleRate
        self.chunkDurationSeconds = chunkDurationSeconds
        self.interval = interval
    }

    public func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        let url = url
        let targetSampleRate = targetSampleRate
        let chunkSampleCount = max(1, Int(Double(targetSampleRate) * chunkDurationSeconds))
        let interval = interval

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let samples = try AudioFileLoader.load(url: url, targetSampleRate: targetSampleRate)
                    var offset = 0

                    while offset < samples.count {
                        try Task.checkCancellation()
                        let end = min(offset + chunkSampleCount, samples.count)
                        let chunkSamples = Array(samples[offset..<end])
                        continuation.yield(
                            HeptapodAudioChunk(
                                pcm16: HeptapodSpeechSwiftAudioSamples.pcm16Data(from: chunkSamples),
                                sampleRate: targetSampleRate
                            )
                        )
                        offset = end

                        if let interval, offset < samples.count {
                            try await Task.sleep(for: interval)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
