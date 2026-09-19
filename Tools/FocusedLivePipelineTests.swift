import Foundation

private enum FocusedTestError: Error {
    case failed(String)
    case playbackFailed
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw FocusedTestError.failed(message)
    }
}

private struct FocusedRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact
    let finalTranscript: HeptapodTranscriptSegment?

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        let text = String(decoding: chunk.pcm16, as: UTF8.self)
        return text.isEmpty ? nil : HeptapodTranscriptSegment(text: text, languageCode: languageHint)
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        finalTranscript
    }

    func reset() async {}
}

private struct FocusedTranslator: HeptapodTextTranslator {
    let descriptor = HeptapodModelDescriptor.madladTranslator
    let returnedTargetLanguage: String?

    func prepare() async throws {}

    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        HeptapodTranslatedText(
            sourceText: text,
            translatedText: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: returnedTargetLanguage ?? targetLanguageCode
        )
    }
}

private actor FocusedSynthesizer: HeptapodSpeechSynthesizer {
    nonisolated let descriptor: HeptapodModelDescriptor
    private var calls: [(text: String, languageCode: String)] = []

    init(streaming: Bool = false) {
        descriptor = streaming ? .mossTTSNano : .kokoroTTS
    }

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        calls.append((text, languageCode))
        return HeptapodSynthesizedSpeech(
            pcm16: Data([1, 1]),
            sampleRate: 24_000,
            languageCode: languageCode
        )
    }

    func synthesizeStream(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        calls.append((text, languageCode))
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        pair.continuation.yield(HeptapodSynthesizedSpeech(
            pcm16: Data(),
            sampleRate: 8_000,
            languageCode: languageCode
        ))
        pair.continuation.yield(HeptapodSynthesizedSpeech(
            pcm16: Data([2, 2]),
            sampleRate: 24_000,
            languageCode: languageCode
        ))
        pair.continuation.finish()
        return pair.stream
    }

    func recordedCalls() -> [(text: String, languageCode: String)] {
        calls
    }
}

private actor FailingPlaybackSink: HeptapodSpeechPlaybackSink {
    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        throw FocusedTestError.playbackFailed
    }
}

private struct AllSpeechVAD: HeptapodSegmentingVoiceActivityDetector {
    let descriptor = HeptapodModelDescriptor.sileroVAD

    func prepare() async throws {}

    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        chunk.pcm16.isEmpty == false
    }

    func speechSegments(in chunk: HeptapodAudioChunk) async throws -> [HeptapodVoiceActivitySegment] {
        [HeptapodVoiceActivitySegment(startTime: 0, endTime: chunk.duration)]
    }
}

private actor RecordingASR: HeptapodSpeechRecognizer {
    nonisolated let descriptor = HeptapodModelDescriptor.qwenASRCompact
    private var received: [HeptapodAudioChunk] = []

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        received.append(chunk)
        return nil
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    func reset() async {}

    func receivedChunks() -> [HeptapodAudioChunk] {
        received
    }
}

private func makePipeline(
    synthesizer: FocusedSynthesizer,
    finalTranscript: HeptapodTranscriptSegment? = nil,
    returnedTargetLanguage: String? = nil
) throws -> HeptapodSpeechToSpeechPipeline {
    try HeptapodSpeechToSpeechPipeline(
        configuration: HeptapodPipelineConfiguration(
            speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
            textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
            speechSynthesisModelID: synthesizer.descriptor.id
        ),
        recognizer: FocusedRecognizer(finalTranscript: finalTranscript),
        translator: FocusedTranslator(returnedTargetLanguage: returnedTargetLanguage),
        synthesizer: synthesizer
    )
}

@main
private struct FocusedLivePipelineTests {
    static func main() async throws {
        try testChunker()
        print("PASS chunker order, clauses, and 18-word limit")

        try await testDemandDrivenFallback()
        print("PASS demand-driven fallback synthesis")

        try await testFinalTranscriptAndTranslationLanguage()
        print("PASS final transcript guard and translated language")

        try await testEmptyNativeStreamingChunk()
        print("PASS empty native streaming chunk handling")

        try await testASRWindowFormatChanges()
        print("PASS ASR window channels and format resets")

        try await testPlaybackFailurePropagation()
        print("PASS playback failure propagation")
    }

    private static func testChunker() throws {
        let clauseChunks = HeptapodSpeechSynthesisTextChunker.chunks(
            in: "Bir iki üç dört beş, altı yedi sekiz dokuz on; on bir on iki on üç on dört.",
            maximumWordsPerChunk: 6,
            minimumWordsPerChunk: 2
        )
        try expect(clauseChunks == [
            "Bir iki üç dört beş,",
            "altı yedi sekiz dokuz on;",
            "on bir on iki on üç",
            "on dört."
        ], "clause boundaries or order changed")

        let original = Array(repeating: "Türkçe", count: 42).joined(separator: "  ")
        let chunks = HeptapodSpeechSynthesisTextChunker.chunks(in: original)
        try expect(chunks.count > 1, "long sentence was not split")
        try expect(chunks.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 18 }, "word limit exceeded")
        try expect(chunks.joined(separator: "  ") == original, "original spacing or text changed")
    }

    private static func testDemandDrivenFallback() async throws {
        let synthesizer = FocusedSynthesizer()
        let pipeline = try makePipeline(synthesizer: synthesizer)
        let translation = HeptapodTranslatedText(
            sourceText: "source",
            translatedText: Array(repeating: "kelime", count: 40).joined(separator: " "),
            sourceLanguageCode: "en",
            targetLanguageCode: "tr"
        )
        let stream = await pipeline.synthesizeLiveStream(translation)
        let callsBeforeDemand = await synthesizer.recordedCalls()
        try expect(callsBeforeDemand.isEmpty, "fallback synthesized before demand")
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        try expect(first?.pcm16 == Data([1, 1]), "first fallback chunk missing")
        let callsAfterFirstChunk = await synthesizer.recordedCalls()
        try expect(callsAfterFirstChunk.count == 1, "fallback synthesized future chunks")
    }

    private static func testFinalTranscriptAndTranslationLanguage() async throws {
        let synthesizer = FocusedSynthesizer()
        let partialPipeline = try makePipeline(
            synthesizer: synthesizer,
            finalTranscript: HeptapodTranscriptSegment(text: "partial", isFinal: false),
            returnedTargetLanguage: "fr"
        )
        let partial = try await partialPipeline.finishDetailed(
            sourceLanguageCode: "en",
            targetLanguageCode: "tr"
        )
        try expect(partial == nil, "non-final transcript was synthesized")
        let callsAfterPartial = await synthesizer.recordedCalls()
        try expect(callsAfterPartial.isEmpty, "non-final transcript reached synthesizer")

        let transcript = HeptapodTranscriptSegment(text: "hello", languageCode: "en")
        let result = try await partialPipeline.translateAndSynthesize(
            transcript,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr"
        )
        try expect(result.translation.targetLanguageCode == "fr", "translator target was not returned")
        let callsAfterBatch = await synthesizer.recordedCalls()
        try expect(callsAfterBatch.last?.languageCode == "fr", "batch TTS ignored translated target")

        let finalPipeline = try makePipeline(
            synthesizer: synthesizer,
            finalTranscript: transcript,
            returnedTargetLanguage: "fr"
        )
        _ = try await finalPipeline.finishDetailed(sourceLanguageCode: "en", targetLanguageCode: "tr")
        let callsAfterFinal = await synthesizer.recordedCalls()
        try expect(callsAfterFinal.last?.languageCode == "fr", "final TTS ignored translated target")
    }

    private static func testEmptyNativeStreamingChunk() async throws {
        let synthesizer = FocusedSynthesizer(streaming: true)
        let pipeline = try makePipeline(synthesizer: synthesizer)
        let session = HeptapodLiveSpeechSession(
            pipeline: pipeline,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr"
        )
        let input = HeptapodArrayAudioChunkSource(audioChunks: [
            HeptapodAudioChunk(pcm16: Data("hello".utf8), sampleRate: 16_000)
        ])
        let events = await session.run(chunks: input.chunks())
        var result: HeptapodSpeechToSpeechResult?
        var audioReadyCount = 0
        for try await event in events {
            switch event {
            case .result(_, let value):
                result = value
            case .synthesisAudioReady:
                audioReadyCount += 1
            default:
                break
            }
        }
        try expect(result?.speech.pcm16 == Data([2, 2]), "empty native chunk polluted result")
        try expect(result?.speech.sampleRate == 24_000, "empty native chunk set sample rate")
        try expect(audioReadyCount == 1, "first audio event count changed")
    }

    private static func testPlaybackFailurePropagation() async throws {
        let synthesizer = FocusedSynthesizer()
        let pipeline = try makePipeline(synthesizer: synthesizer)
        let session = HeptapodLiveSpeechSession(
            pipeline: pipeline,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            playbackSink: FailingPlaybackSink()
        )
        let input = HeptapodArrayAudioChunkSource(audioChunks: [
            HeptapodAudioChunk(pcm16: Data("hello".utf8), sampleRate: 16_000)
        ])
        let events = await session.run(chunks: input.chunks())
        do {
            for try await _ in events {}
            throw FocusedTestError.failed("playback error was not propagated")
        } catch FocusedTestError.playbackFailed {
            return
        }
    }

    private static func testASRWindowFormatChanges() async throws {
        let recognizer = RecordingASR()
        let synthesizer = FocusedSynthesizer()
        let pipeline = try HeptapodSpeechToSpeechPipeline(
            configuration: HeptapodPipelineConfiguration(
                speechRecognitionModelID: recognizer.descriptor.id,
                textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
                speechSynthesisModelID: synthesizer.descriptor.id,
                voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
            ),
            vad: AllSpeechVAD(),
            recognizer: recognizer,
            translator: FocusedTranslator(returnedTargetLanguage: nil),
            synthesizer: synthesizer
        )
        let session = HeptapodLiveSpeechSession(
            pipeline: pipeline,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr"
        )
        let first = HeptapodAudioChunk(pcm16: Data([1, 0, 2, 0]), sampleRate: 16_000, channelCount: 2)
        let second = HeptapodAudioChunk(pcm16: Data([3, 0, 4, 0]), sampleRate: 16_000, channelCount: 2)
        let third = HeptapodAudioChunk(pcm16: Data([5, 0]), sampleRate: 48_000, channelCount: 1)
        let fourth = HeptapodAudioChunk(pcm16: Data([6, 0, 7, 0]), sampleRate: 48_000, channelCount: 2)
        let input = HeptapodArrayAudioChunkSource(audioChunks: [first, second, third, fourth])
        let events = await session.runSentenceBuffered(
            chunks: input.chunks(),
            endpointing: HeptapodSentenceEndpointingConfiguration(
                asrStabilization: HeptapodASRStabilizationConfiguration(
                    maximumWindowChunks: 3,
                    minimumStableWords: 2
                )
            )
        )
        for try await _ in events {}

        let received = await recognizer.receivedChunks()
        try expect(received.count == 4, "ASR did not receive each window")
        try expect(received[0].channelCount == 2, "first channel count changed")
        try expect(received[1].channelCount == 2, "combined channel count changed")
        try expect(received[1].pcm16 == first.pcm16 + second.pcm16, "same-format window was not combined")
        try expect(received[2].sampleRate == 48_000 && received[2].channelCount == 1, "sample-rate change was mislabeled")
        try expect(received[2].pcm16 == third.pcm16, "old PCM survived a sample-rate change")
        try expect(received[3].channelCount == 2 && received[3].pcm16 == fourth.pcm16, "old PCM survived a channel change")
    }
}
