import Foundation

public protocol HeptapodEngineComponent: Sendable {
    var descriptor: HeptapodModelDescriptor { get }
    func prepare() async throws
}

public protocol HeptapodVoiceActivityDetector: HeptapodEngineComponent {
    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool
}

public protocol HeptapodSpeechRecognizer: HeptapodEngineComponent {
    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment?
    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment?
    func reset() async
}

public protocol HeptapodTextTranslator: HeptapodEngineComponent {
    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText
}

public protocol HeptapodSpeechSynthesizer: HeptapodEngineComponent {
    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech
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
