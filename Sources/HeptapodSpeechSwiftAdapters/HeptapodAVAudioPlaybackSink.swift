@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodAVAudioPlaybackSink:
    HeptapodStreamingSpeechPlaybackSink,
    HeptapodPlaybackBacklogAware
{
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let basePlaybackRate: Float
    private let maximumPlaybackRate: Float
    private let startupBufferDuration: TimeInterval
    private var isPrepared = false
    private var playbackSampleRate: Double?
    private var playbackChannelCount: AVAudioChannelCount?
    private var requestedPlaybackRate: Float

    public init(
        playbackRate: Float = 1,
        maximumPlaybackRate: Float = 1.15,
        startupBufferDuration: TimeInterval = 0.16
    ) {
        let normalizedPlaybackRate = min(max(playbackRate, 0.5), 2)
        basePlaybackRate = normalizedPlaybackRate
        self.maximumPlaybackRate = min(max(maximumPlaybackRate, basePlaybackRate), 2)
        self.startupBufferDuration = max(0, startupBufferDuration)
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
        var completionTasks: [Task<Void, Never>] = []
        var bufferedDuration: TimeInterval = 0
        var didStartPlayback = false
        var streamSampleRate: Int?

        for try await speech in speechStream {
            guard speech.pcm16.isEmpty == false else { continue }
            if let streamSampleRate, streamSampleRate != speech.sampleRate {
                throw HeptapodAVAudioPlaybackError.inconsistentSampleRate(
                    expected: streamSampleRate,
                    actual: speech.sampleRate
                )
            }
            streamSampleRate = speech.sampleRate

            let scheduled = try schedule(speech)
            completionTasks.append(scheduled.completion)
            bufferedDuration += scheduled.duration
            if didStartPlayback == false, bufferedDuration >= startupBufferDuration {
                player.play()
                didStartPlayback = true
            } else if didStartPlayback, player.isPlaying == false {
                player.play()
            }
        }

        guard completionTasks.isEmpty == false else {
            throw HeptapodAVAudioPlaybackError.emptySpeech
        }
        if didStartPlayback == false {
            player.play()
        }
        for completion in completionTasks {
            await completion.value
        }
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
            for await _ in pair.stream {}
        }
        return (
            duration: Double(samples.count) / Double(speech.sampleRate),
            completion: completion
        )
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
