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

    public func prepare(
        includeSynthesis: Bool = true,
        synthesisLanguageCode: String? = nil
    ) async throws {
        try await vad?.prepare()
        try await recognizer.prepare()
        try await translator.prepare()
        if includeSynthesis {
            try await synthesizer.prepare(languageCode: synthesisLanguageCode)
        }
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
        guard let transcript = try await transcribeSpeech(
            chunk,
            sourceLanguageCode: sourceLanguageCode
        ) else {
            return nil
        }

        return try await translateAndSynthesize(
            transcript,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            voiceID: voiceID
        )
    }

    public func transcribeSpeech(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?
    ) async throws -> HeptapodTranscriptSegment? {
        guard try await containsSpeech(chunk) else { return nil }

        return try await recognizeSpeech(chunk, sourceLanguageCode: sourceLanguageCode)
    }

    public func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        guard let vad else {
            return true
        }
        return try await vad.containsSpeech(chunk)
    }

    public func speechSegments(in chunk: HeptapodAudioChunk) async throws -> [HeptapodVoiceActivitySegment] {
        if let segmentingVAD = vad as? any HeptapodSegmentingVoiceActivityDetector {
            return try await segmentingVAD.speechSegments(in: chunk)
        }
        guard try await containsSpeech(chunk) else {
            return []
        }
        return [HeptapodVoiceActivitySegment(startTime: 0, endTime: chunk.duration)]
    }

    public func recognizeSpeech(
        _ chunk: HeptapodAudioChunk,
        sourceLanguageCode: String?
    ) async throws -> HeptapodTranscriptSegment? {
        guard let transcript = try await recognizer.transcribe(chunk, languageHint: sourceLanguageCode) else {
            return nil
        }
        guard transcript.isFinal else {
            return nil
        }

        return transcript
    }

    public func translateAndSynthesize(
        _ transcript: HeptapodTranscriptSegment,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil
    ) async throws -> HeptapodSpeechToSpeechResult {

        let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw HeptapodEngineError.emptyTranscript
        }

        let translated = try await translateTranscript(
            transcript,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let speech = try await synthesizer.synthesize(
            translated.translatedText,
            languageCode: translated.targetLanguageCode,
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
        guard transcript.isFinal else {
            return nil
        }

        let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return nil
        }

        let translated = try await translateTranscript(
            transcript,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let speech = try await synthesizer.synthesize(
            translated.translatedText,
            languageCode: translated.targetLanguageCode,
            voiceID: voiceID
        )

        return HeptapodSpeechToSpeechResult(
            transcript: transcript,
            translation: translated,
            speech: speech
        )
    }

    public func translateTranscript(
        _ transcript: HeptapodTranscriptSegment,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw HeptapodEngineError.emptyTranscript
        }

        return try await translator.translate(
            trimmedTranscript,
            sourceLanguageCode: transcript.languageCode ?? sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    public func synthesizeStream(
        _ translation: HeptapodTranslatedText,
        voiceID: String? = nil
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        await synthesizer.synthesizeStream(
            translation.translatedText,
            languageCode: translation.targetLanguageCode,
            voiceID: voiceID
        )
    }

    func synthesizeLiveStream(
        _ translation: HeptapodTranslatedText,
        voiceID: String? = nil
    ) async -> HeptapodLiveSpeechStream {
        if synthesizer.descriptor.capabilities.contains(.streamingTTS) {
            return .native(await synthesizeStream(translation, voiceID: voiceID))
        }

        let textChunks = HeptapodSpeechSynthesisTextChunker.chunks(
            in: translation.translatedText,
            maximumWordsPerChunk: 18
        )
        return .fallback(DemandDrivenSpeechStream(
            textChunks: textChunks,
            synthesizer: synthesizer,
            languageCode: translation.targetLanguageCode,
            voiceID: voiceID
        ))
    }
}

enum HeptapodLiveSpeechStream: AsyncSequence, Sendable {
    typealias Element = HeptapodSynthesizedSpeech

    case native(AsyncThrowingStream<Element, Error>)
    case fallback(DemandDrivenSpeechStream)

    struct Iterator: AsyncIteratorProtocol {
        fileprivate enum Source {
            case native(AsyncThrowingStream<Element, Error>.Iterator)
            case fallback(DemandDrivenSpeechStream.Iterator)
        }

        private var source: Source

        mutating func next() async throws -> Element? {
            switch source {
            case .native(var iterator):
                let value = try await iterator.next()
                source = .native(iterator)
                return value
            case .fallback(var iterator):
                let value = try await iterator.next()
                source = .fallback(iterator)
                return value
            }
        }

        fileprivate init(_ source: Source) {
            self.source = source
        }
    }

    func makeAsyncIterator() -> Iterator {
        switch self {
        case .native(let stream):
            Iterator(.native(stream.makeAsyncIterator()))
        case .fallback(let stream):
            Iterator(.fallback(stream.makeAsyncIterator()))
        }
    }
}

struct DemandDrivenSpeechStream: AsyncSequence, Sendable {
    typealias Element = HeptapodSynthesizedSpeech

    let textChunks: [String]
    let synthesizer: any HeptapodSpeechSynthesizer
    let languageCode: String
    let voiceID: String?

    struct Iterator: AsyncIteratorProtocol, Sendable {
        private let textChunks: [String]
        private let synthesizer: any HeptapodSpeechSynthesizer
        private let languageCode: String
        private let voiceID: String?
        private var nextIndex = 0

        init(
            textChunks: [String],
            synthesizer: any HeptapodSpeechSynthesizer,
            languageCode: String,
            voiceID: String?
        ) {
            self.textChunks = textChunks
            self.synthesizer = synthesizer
            self.languageCode = languageCode
            self.voiceID = voiceID
        }

        mutating func next() async throws -> HeptapodSynthesizedSpeech? {
            try Task.checkCancellation()
            guard nextIndex < textChunks.count else {
                return nil
            }

            let textChunk = textChunks[nextIndex]
            let speech = try await synthesizer.synthesize(
                textChunk,
                languageCode: languageCode,
                voiceID: voiceID
            )
            try Task.checkCancellation()
            nextIndex += 1
            return speech
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(
            textChunks: textChunks,
            synthesizer: synthesizer,
            languageCode: languageCode,
            voiceID: voiceID
        )
    }
}
