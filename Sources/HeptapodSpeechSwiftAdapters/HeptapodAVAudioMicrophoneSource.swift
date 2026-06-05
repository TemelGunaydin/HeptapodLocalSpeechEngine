import AudioCommon
@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public final class HeptapodAVAudioMicrophoneSource: HeptapodAudioChunkSource {
    public let targetSampleRate: Int
    public let chunkDurationSeconds: Double
    public let maximumDurationSeconds: Double?

    public init(
        targetSampleRate: Int = 16_000,
        chunkDurationSeconds: Double = 1.0,
        maximumDurationSeconds: Double? = nil
    ) {
        self.targetSampleRate = targetSampleRate
        self.chunkDurationSeconds = chunkDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    public func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        let targetSampleRate = targetSampleRate
        let chunkSampleCount = max(1, Int(Double(targetSampleRate) * chunkDurationSeconds))
        let maximumDurationSeconds = maximumDurationSeconds

        return AsyncThrowingStream { continuation in
            let engineBox = MicrophoneEngineBox(engine: AVAudioEngine())
            let state = MicrophoneChunkState(
                continuation: continuation,
                targetSampleRate: targetSampleRate,
                chunkSampleCount: chunkSampleCount,
                maximumSampleCount: maximumDurationSeconds.map { Int($0 * Double(targetSampleRate)) }
            )

            do {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
                #endif

                let input = engineBox.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(
                    onBus: 0,
                    bufferSize: AVAudioFrameCount(chunkSampleCount),
                    format: format
                ) { buffer, _ in
                    state.consume(buffer: buffer, inputSampleRate: Int(format.sampleRate))
                }

                try engineBox.engine.start()
            } catch {
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { _ in
                engineBox.engine.inputNode.removeTap(onBus: 0)
                engineBox.engine.stop()
            }
        }
    }
}

private final class MicrophoneEngineBox: @unchecked Sendable {
    let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }
}

private final class MicrophoneChunkState: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation
    private let targetSampleRate: Int
    private let chunkSampleCount: Int
    private let maximumSampleCount: Int?
    private var samples: [Float] = []
    private var emittedSampleCount = 0

    init(
        continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation,
        targetSampleRate: Int,
        chunkSampleCount: Int,
        maximumSampleCount: Int?
    ) {
        self.continuation = continuation
        self.targetSampleRate = targetSampleRate
        self.chunkSampleCount = chunkSampleCount
        self.maximumSampleCount = maximumSampleCount
    }

    func consume(buffer: AVAudioPCMBuffer, inputSampleRate: Int) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        var incoming = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        if inputSampleRate != targetSampleRate {
            incoming = AudioFileLoader.resample(incoming, from: inputSampleRate, to: targetSampleRate)
        }

        lock.lock()
        samples.append(contentsOf: incoming)

        while samples.count >= chunkSampleCount {
            let chunkSamples = Array(samples.prefix(chunkSampleCount))
            samples.removeFirst(chunkSampleCount)
            emittedSampleCount += chunkSampleCount

            continuation.yield(
                HeptapodAudioChunk(
                    pcm16: HeptapodSpeechSwiftAudioSamples.pcm16Data(from: chunkSamples),
                    sampleRate: targetSampleRate
                )
            )

            if let maximumSampleCount, emittedSampleCount >= maximumSampleCount {
                continuation.finish()
                break
            }
        }
        lock.unlock()
    }
}
