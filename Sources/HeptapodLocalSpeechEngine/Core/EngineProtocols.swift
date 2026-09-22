import Foundation

public protocol HeptapodEngineComponent: Sendable {
    var descriptor: HeptapodModelDescriptor { get }
    func prepare() async throws
}

public protocol HeptapodVoiceActivityDetector: HeptapodEngineComponent {
    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool
}

public protocol HeptapodSegmentingVoiceActivityDetector: HeptapodVoiceActivityDetector {
    func speechSegments(in chunk: HeptapodAudioChunk) async throws -> [HeptapodVoiceActivitySegment]
}

public protocol HeptapodSpeechRecognizer: HeptapodEngineComponent {
    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment?
    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment?
    func reset() async
}

/// An incremental recognition session bound to a single utterance.
///
/// Audio is fed with `pushAudio`, which returns updated cumulative
/// hypotheses (`isFinal == false`) as the recognizer decodes more speech.
/// The utterance ends with `finishUtterance`, which returns the final
/// transcript, or with `abandonUtterance`, which discards decoder state.
///
/// Sessions are not internally synchronized; owners must serialize all
/// calls and use one session per utterance.
public protocol HeptapodStreamingRecognitionSession: AnyObject, Sendable {
    func pushAudio(_ chunk: HeptapodAudioChunk) async throws -> [HeptapodTranscriptSegment]
    func finishUtterance() async throws -> HeptapodTranscriptSegment?
    func abandonUtterance() async
}

/// A recognizer that can expose incremental hypotheses instead of only
/// whole-buffer transcripts.
public protocol HeptapodStreamingSpeechRecognizer: HeptapodSpeechRecognizer {
    func openStreamingSession(languageHint: String?) async throws -> any HeptapodStreamingRecognitionSession
}

public protocol HeptapodTextTranslator: HeptapodEngineComponent {
    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText
}

public protocol HeptapodSpeechSynthesizer: HeptapodEngineComponent {
    func prepare(languageCode: String?) async throws

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech

    func synthesizeStream(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>
}

public extension HeptapodSpeechSynthesizer {
    func prepare(languageCode: String?) async throws {
        try await prepare()
    }

    func synthesizeStream(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        let task = Task {
            do {
                pair.continuation.yield(
                    try await synthesize(
                        text,
                        languageCode: languageCode,
                        voiceID: voiceID
                    )
                )
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in
            task.cancel()
        }
        return pair.stream
    }
}

public protocol HeptapodDirectSpeechTranslator: HeptapodEngineComponent {
    func translateSpeech(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech?
}

public enum HeptapodEngineError: LocalizedError, Sendable {
    case unsupportedModel(String)
    case missingComponent(HeptapodPipelineStage)
    case adapterNotImplemented(String)
    case noSpeechDetected
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let id):
            "Unsupported local speech model: \(id)"
        case .missingComponent(let stage):
            "Missing local speech pipeline component for \(stage.rawValue)"
        case .adapterNotImplemented(let id):
            "Model adapter is not implemented yet: \(id)"
        case .noSpeechDetected:
            "No speech was detected in the audio chunk."
        case .emptyTranscript:
            "Speech recognition returned an empty transcript."
        }
    }
}
