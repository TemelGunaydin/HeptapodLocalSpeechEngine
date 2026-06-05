@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodAVAudioPlaybackSink: HeptapodSpeechPlaybackSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isPrepared = false

    public init() {}

    public func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        try prepareIfNeeded()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(speech.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw HeptapodAVAudioPlaybackError.invalidFormat
        }

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

    private func prepareIfNeeded() throws {
        guard isPrepared == false else {
            return
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif

        engine.attach(player)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.outputNode, format: outputFormat)
        try engine.start()
        isPrepared = true
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
