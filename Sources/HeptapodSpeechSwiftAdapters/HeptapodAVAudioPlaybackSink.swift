@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodAVAudioPlaybackSink:
    HeptapodStreamingSpeechPlaybackSink,
    HeptapodCancellableSpeechPlaybackSink,
    HeptapodPlaybackBacklogAware
{
    private struct ScheduledBuffer {
        let duration: TimeInterval
        let completion: Task<Void, Never>
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let basePlaybackRate: Float
    private let maximumPlaybackRate: Float
    private let startupBufferDuration: TimeInterval
    private let maximumBufferedDuration: TimeInterval
    private var isPrepared = false
    private var playbackSampleRate: Double?
    private var playbackChannelCount: AVAudioChannelCount?
    private var requestedPlaybackRate: Float
    private var scheduledBuffers: [ScheduledBuffer] = []
    private var bufferedDuration: TimeInterval = 0
    private var playbackGeneration = 0

    public init(
        playbackRate: Float = 1,
        maximumPlaybackRate: Float = 1.15,
        startupBufferDuration: TimeInterval = 0.16,
        maximumBufferedDuration: TimeInterval = 1.0
    ) {
        let normalizedPlaybackRate = min(max(playbackRate, 0.5), 2)
        basePlaybackRate = normalizedPlaybackRate
        self.maximumPlaybackRate = min(max(maximumPlaybackRate, basePlaybackRate), 2)
        self.startupBufferDuration = max(0, startupBufferDuration)
        self.maximumBufferedDuration = max(
            self.startupBufferDuration,
            max(0, maximumBufferedDuration)
        )
        requestedPlaybackRate = normalizedPlaybackRate
    }

    public func prepare(sampleRate: Int = 24_000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw HeptapodAVAudioPlaybackError.invalidFormat
        }
        try prepareIfNeeded(format: format)
    }

    public func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        pair.continuation.yield(speech)
        pair.continuation.finish()
        try await play(pair.stream)
    }

    public func play(
        _ speechStream: AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>
    ) async throws {
        let generation = playbackGeneration
        var bufferedDuration: TimeInterval = 0
        var didStartPlayback = false
        var didScheduleAudio = false
        var streamSampleRate: Int?

        do {
            for try await speech in speechStream {
                try Task.checkCancellation()
                guard playbackGeneration == generation else {
                    throw CancellationError()
                }
                guard speech.pcm16.isEmpty == false else { continue }
                if let streamSampleRate, streamSampleRate != speech.sampleRate {
                    throw HeptapodAVAudioPlaybackError.inconsistentSampleRate(
                        expected: streamSampleRate,
                        actual: speech.sampleRate
                    )
                }
                streamSampleRate = speech.sampleRate

                let scheduled = try schedule(speech)
                didScheduleAudio = true
                let scheduledBuffer = ScheduledBuffer(
                    duration: scheduled.duration,
                    completion: scheduled.completion
                )
                scheduledBuffers.append(scheduledBuffer)
                self.bufferedDuration += scheduled.duration
                bufferedDuration += scheduled.duration
                if didStartPlayback == false, bufferedDuration >= startupBufferDuration {
                    player.play()
                    didStartPlayback = true
                } else if didStartPlayback, player.isPlaying == false {
                    player.play()
                }

                while self.bufferedDuration > maximumBufferedDuration {
                    try await waitForOldestBuffer(generation: generation)
                }
            }

            guard playbackGeneration == generation else {
                throw CancellationError()
            }
            guard didScheduleAudio else {
                throw HeptapodAVAudioPlaybackError.emptySpeech
            }
            if didStartPlayback == false {
                player.play()
            }
            while scheduledBuffers.isEmpty == false {
                try await waitForOldestBuffer(generation: generation)
            }
        } catch {
            if playbackGeneration == generation {
                await cancelPlayback()
            }
            throw error
        }
    }

    public func cancelPlayback() async {
        playbackGeneration &+= 1
        player.stop()
        for scheduledBuffer in scheduledBuffers {
            scheduledBuffer.completion.cancel()
        }
        scheduledBuffers.removeAll()
        bufferedDuration = 0
        requestedPlaybackRate = basePlaybackRate
        timePitch.rate = requestedPlaybackRate
    }

    public func setPlaybackBacklog(segmentCount: Int) async {
        let rateIncrease: Float
        switch segmentCount {
        case ...1:
            rateIncrease = 0
        case 2:
            rateIncrease = 0.05
        case 3:
            rateIncrease = 0.10
        default:
            rateIncrease = 0.15
        }
        requestedPlaybackRate = min(maximumPlaybackRate, basePlaybackRate + rateIncrease)
        timePitch.rate = requestedPlaybackRate
    }

    private func schedule(
        _ speech: HeptapodSynthesizedSpeech
    ) throws -> (duration: TimeInterval, completion: Task<Void, Never>) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(speech.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw HeptapodAVAudioPlaybackError.invalidFormat
        }
        try prepareIfNeeded(format: format)

        let samples = HeptapodSpeechSwiftAudioSamples.floatSamples(fromPCM16: speech.pcm16)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw HeptapodAVAudioPlaybackError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for index in samples.indices {
                channel[index] = samples[index]
            }
        }

        let pair = AsyncStream<Void>.makeStream()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            pair.continuation.yield(())
            pair.continuation.finish()
        }
        let completion = Task {
            await withTaskCancellationHandler(operation: {
                for await _ in pair.stream {}
            }, onCancel: {
                pair.continuation.finish()
            })
        }
        return (
            duration: Double(samples.count) / Double(speech.sampleRate),
            completion: completion
        )
    }

    private func waitForOldestBuffer(generation: Int) async throws {
        guard let oldest = scheduledBuffers.first else {
            return
        }

        try await withTaskCancellationHandler(operation: {
            await oldest.completion.value
            try Task.checkCancellation()
        }, onCancel: {
            oldest.completion.cancel()
        })

        guard playbackGeneration == generation else {
            throw CancellationError()
        }
        guard scheduledBuffers.isEmpty == false else {
            return
        }
        scheduledBuffers.removeFirst()
        bufferedDuration = max(0, bufferedDuration - oldest.duration)
    }

    private func prepareIfNeeded(format: AVAudioFormat) throws {
        if isPrepared,
           playbackSampleRate == format.sampleRate,
           playbackChannelCount == format.channelCount {
            return
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif

        if isPrepared {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.stop()
        } else {
            engine.attach(player)
            engine.attach(timePitch)
        }

        timePitch.rate = requestedPlaybackRate
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        if engine.isRunning == false {
            try engine.start()
        }
        isPrepared = true
        playbackSampleRate = format.sampleRate
        playbackChannelCount = format.channelCount
    }
}

public enum HeptapodAVAudioPlaybackError: LocalizedError, Sendable {
    case emptySpeech
    case inconsistentSampleRate(expected: Int, actual: Int)
    case invalidFormat
    case bufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .emptySpeech:
            "Synthesized speech stream contained no audio."
        case .inconsistentSampleRate(let expected, let actual):
            "Synthesized speech stream changed sample rate from \(expected) Hz to \(actual) Hz."
        case .invalidFormat:
            "Could not create an AVAudioFormat for synthesized speech playback."
        case .bufferCreationFailed:
            "Could not create an AVAudioPCMBuffer for synthesized speech playback."
        }
    }
}
