@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodAVAudioPlaybackSink: HeptapodSpeechPlaybackSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isPrepared = false
    private var playbackSampleRate: Double?
    private var playbackChannelCount: AVAudioChannelCount?

    public init() {}

    public func play(_ speech: HeptapodSynthesizedSpeech) async throws {
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
            player.play()
        }
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
            engine.stop()
        } else {
            engine.attach(player)
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
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
    case invalidFormat
    case bufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "Could not create an AVAudioFormat for synthesized speech playback."
        case .bufferCreationFailed:
            "Could not create an AVAudioPCMBuffer for synthesized speech playback."
        }
    }
}
