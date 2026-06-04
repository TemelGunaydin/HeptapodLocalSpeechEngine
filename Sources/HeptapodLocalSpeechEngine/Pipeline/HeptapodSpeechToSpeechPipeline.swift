import Foundation

public actor HeptapodSpeechToSpeechPipeline {
    public let configuration: HeptapodPipelineConfiguration
    public let catalog: HeptapodModelCatalog

    private let vad: (any HeptapodVoiceActivityDetector)?
    private let recognizer: any HeptapodSpeechRecognizer
    private let translator: any HeptapodTextTranslator
    private let synthesizer: any HeptapodSpeechSynthesizer

    public init(
        configuration: HeptapodPipelineConfiguration,
        catalog: HeptapodModelCatalog = HeptapodModelCatalog(),
        vad: (any HeptapodVoiceActivityDetector)? = nil,
        recognizer: any HeptapodSpeechRecognizer,
        translator: any HeptapodTextTranslator,
        synthesizer: any HeptapodSpeechSynthesizer
    ) throws {
        try configuration.validate(in: catalog)
        self.configuration = configuration
        self.catalog = catalog
        self.vad = vad
        self.recognizer = recognizer
        self.translator = translator
        self.synthesizer = synthesizer
    }

    public func prepare() async throws {
        try await vad?.prepare()
        try await recognizer.prepare()
        try await translator.prepare()
        try await synthesizer.prepare()
    }

    public func process(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil
    ) async throws -> HeptapodSynthesizedSpeech? {
        try await processDetailed(
            chunk,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            voiceID: voiceID
        )?.speech
    }

    public func processDetailed(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil
    ) async throws -> HeptapodSpeechToSpeechResult? {
        if let vad {
            let containsSpeech = try await vad.containsSpeech(chunk)
            guard containsSpeech else { return nil }
        }

        guard let transcript = try await recognizer.transcribe(chunk, languageHint: sourceLanguageCode) else {
            return nil
        }
        guard transcript.isFinal else {
            return nil
        }

        let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw HeptapodEngineError.emptyTranscript
        }

        let translated = try await translator.translate(
            trimmedTranscript,
            sourceLanguageCode: transcript.languageCode ?? sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let speech = try await synthesizer.synthesize(
            translated.translatedText,
            languageCode: targetLanguageCode,
            voiceID: voiceID
        )

        return HeptapodSpeechToSpeechResult(
            transcript: transcript,
            translation: translated,
            speech: speech
        )
    }

    public func finish(
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil
    ) async throws -> HeptapodSynthesizedSpeech? {
        try await finishDetailed(
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            voiceID: voiceID
        )?.speech
    }

    public func finishDetailed(
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil
    ) async throws -> HeptapodSpeechToSpeechResult? {
        guard let transcript = try await recognizer.finish(languageHint: sourceLanguageCode) else {
            return nil
        }

        let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return nil
        }

        let translated = try await translator.translate(
            trimmedTranscript,
            sourceLanguageCode: transcript.languageCode ?? sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let speech = try await synthesizer.synthesize(
            translated.translatedText,
            languageCode: targetLanguageCode,
            voiceID: voiceID
        )

        return HeptapodSpeechToSpeechResult(
            transcript: transcript,
            translation: translated,
            speech: speech
        )
    }
}
