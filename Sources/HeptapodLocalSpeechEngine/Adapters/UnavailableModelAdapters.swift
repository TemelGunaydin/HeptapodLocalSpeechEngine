import Foundation

public struct HeptapodUnavailableVoiceActivityDetector: HeptapodVoiceActivityDetector {
    public let descriptor: HeptapodModelDescriptor

    public init(descriptor: HeptapodModelDescriptor) {
        self.descriptor = descriptor
    }

    public func prepare() async throws {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }
}

public struct HeptapodUnavailableSpeechRecognizer: HeptapodSpeechRecognizer {
    public let descriptor: HeptapodModelDescriptor

    public init(descriptor: HeptapodModelDescriptor) {
        self.descriptor = descriptor
    }

    public func prepare() async throws {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    public func reset() async {}
}

public struct HeptapodUnavailableTextTranslator: HeptapodTextTranslator {
    public let descriptor: HeptapodModelDescriptor

    public init(descriptor: HeptapodModelDescriptor) {
        self.descriptor = descriptor
    }

    public func prepare() async throws {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }
}

public struct HeptapodUnavailableSpeechSynthesizer: HeptapodSpeechSynthesizer {
    public let descriptor: HeptapodModelDescriptor

    public init(descriptor: HeptapodModelDescriptor) {
        self.descriptor = descriptor
    }

    public func prepare() async throws {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }
}

public struct HeptapodUnavailableDirectSpeechTranslator: HeptapodDirectSpeechTranslator {
    public let descriptor: HeptapodModelDescriptor

    public init(descriptor: HeptapodModelDescriptor) {
        self.descriptor = descriptor
    }

    public func prepare() async throws {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }

    public func translateSpeech(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech? {
        throw HeptapodEngineError.adapterNotImplemented(descriptor.id)
    }
}
