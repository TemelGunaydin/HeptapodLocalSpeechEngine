import Foundation
import Testing
@testable import HeptapodLocalSpeechEngine

@Suite(.timeLimit(.minutes(1)))
struct HeptapodLiveLookaheadTests {
    @Test
    func translatesNextSegmentWhileFirstSynthesisWaits() async throws {
        let synthesisGate = LookaheadGate()
        let translator = LookaheadTranslator()
        let synthesizer = LookaheadSynthesizer(firstGate: synthesisGate)
        let session = try makeSession(translator: translator, synthesizer: synthesizer)
        let texts = ["first", "second", "third", "fourth"]
        let events = await session.runSentenceBuffered(chunks: source(texts).chunks())
        var results: [String] = []
        var translationStarts = 0
        var preparedSecondBeforeFirstResult = false

        for try await event in events {
            switch event {
            case .translationStarted:
                translationStarts += 1
                #expect(translationStarts <= results.count + 2)
            case .translationCompleted(let index) where index == 4:
                preparedSecondBeforeFirstResult = results.isEmpty
                synthesisGate.open()
            case .result(_, let result):
                results.append(result.transcript.text)
            default:
                break
            }
        }

        #expect(preparedSecondBeforeFirstResult)
        #expect(results == texts)
        #expect(await translator.recordedTexts() == texts)
        #expect(await synthesizer.recordedTexts() == texts)
    }

    @Test(arguments: [HeptapodLiveOutputMode.speech, .textOnly])
    func drainsEverySegmentInOrder(mode: HeptapodLiveOutputMode) async throws {
        let translator = LookaheadTranslator()
        let synthesizer = LookaheadSynthesizer()
        let session = try makeSession(translator: translator, synthesizer: synthesizer, mode: mode)
        let texts = (1...128).map { "Message number \($0)." }
        let events = await session.runSentenceBuffered(
            chunks: source(texts).chunks(),
            endpointing: HeptapodSentenceEndpointingConfiguration(maximumPendingOutputs: 1)
        )
        var results: [String] = []
        for try await event in events {
            switch event {
            case .result(_, let result):
                results.append(result.transcript.text)
                #expect(result.speech.pcm16 == Data(result.translation.translatedText.utf8))
            case .translation(_, let result):
                results.append(result.transcript.text)
            default:
                break
            }
        }

        #expect(results == texts)
        #expect(await translator.recordedTexts() == texts)
        #expect(await synthesizer.recordedTexts() == (mode == .speech ? texts : []))
    }

    @Test
    func slowPlaybackPreservesEveryOutputWithinItsSegmentLimit() async throws {
        let playbackGate = LookaheadGate()
        let sink = LookaheadPlaybackSink(firstGate: playbackGate)
        let session = try makeSession(
            translator: LookaheadTranslator(),
            synthesizer: LookaheadSynthesizer(),
            sink: sink
        )
        let texts = ["first", "second", "third", "fourth"]
        let events = await session.runSentenceBuffered(
            chunks: source(texts).chunks(),
            endpointing: HeptapodSentenceEndpointingConfiguration(maximumPendingOutputs: 1)
        )
        var results: [String] = []
        var completedPlaybacks = 0
        for try await event in events {
            switch event {
            case .translationCompleted(let index) where index == 6:
                #expect(completedPlaybacks == 0)
                playbackGate.open()
            case .playbackQueued(_, let backlog):
                #expect(backlog <= 1)
            case .playbackCompleted:
                completedPlaybacks += 1
            case .result(_, let result):
                results.append(result.transcript.text)
            default:
                break
            }
        }

        #expect(results == texts)
        #expect(completedPlaybacks == texts.count)
        #expect(await sink.recordedAudio() == texts.map { Data($0.utf8) })
    }

    @Test
    func cancellationStopsBothModelsAndPendingWork() async throws {
        let translator = LookaheadTranslator(secondGate: LookaheadGate())
        let synthesizer = LookaheadSynthesizer(firstGate: LookaheadGate())
        let session = try makeSession(translator: translator, synthesizer: synthesizer)
        let events = await session.runSentenceBuffered(chunks: source(["first", "second", "third"]).chunks())
        let consumer = Task {
            for try await event in events {
                if case .result = event {
                    Issue.record("Cancelled gated synthesis must not emit a result")
                }
            }
        }
        defer { consumer.cancel() }
        try await translator.secondStarted.wait()
        try await synthesizer.firstStarted.wait()
        consumer.cancel()
        _ = await consumer.result
        try await translator.secondFinished.wait()
        try await synthesizer.firstFinished.wait()

        #expect(await translator.recordedTexts() == ["first", "second"])
        #expect(await synthesizer.recordedTexts() == ["first"])
    }

    @Test(arguments: [LookaheadFailure.translation, .synthesis])
    private func failureCancelsTheOtherModelAndFinishesTheStream(failure: LookaheadFailure) async throws {
        let translationGate = LookaheadGate()
        let synthesisGate = LookaheadGate()
        let translator = LookaheadTranslator(secondGate: translationGate, shouldFail: failure == .translation)
        let synthesizer = LookaheadSynthesizer(firstGate: synthesisGate, shouldFail: failure == .synthesis)
        let session = try makeSession(translator: translator, synthesizer: synthesizer)
        let events = await session.runSentenceBuffered(chunks: source(["first", "second", "third"]).chunks())
        let consumer = Task {
            await #expect(throws: failure) {
                for try await event in events {
                    if case .result = event {
                        Issue.record("Failed gated synthesis must not emit a result")
                    }
                }
            }
        }
        defer { consumer.cancel() }
        try await translator.secondStarted.wait()
        try await synthesizer.firstStarted.wait()
        if failure == .translation {
            translationGate.open()
        } else {
            synthesisGate.open()
        }
        _ = await consumer.value
        try await translator.secondFinished.wait()
        try await synthesizer.firstFinished.wait()

        #expect(await translator.recordedTexts() == ["first", "second"])
        #expect(await synthesizer.recordedTexts() == ["first"])
    }

    private func makeSession(
        translator: LookaheadTranslator,
        synthesizer: LookaheadSynthesizer,
        mode: HeptapodLiveOutputMode = .speech,
        sink: (any HeptapodSpeechPlaybackSink)? = nil
    ) throws -> HeptapodLiveSpeechSession {
        let pipeline = try HeptapodSpeechToSpeechPipeline(
            configuration: HeptapodPipelineConfiguration(
                speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
                textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
                speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id
            ),
            recognizer: LookaheadRecognizer(),
            translator: translator,
            synthesizer: synthesizer
        )
        return HeptapodLiveSpeechSession(
            pipeline: pipeline,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            playbackSink: sink,
            outputMode: mode
        )
    }

    private func source(_ texts: [String]) -> HeptapodArrayAudioChunkSource {
        HeptapodArrayAudioChunkSource(audioChunks: texts.flatMap { text in
            [
                HeptapodAudioChunk(pcm16: Data(text.utf8), sampleRate: 16_000),
                HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
            ]
        })
    }
}

private struct LookaheadGate: Sendable {
    private let pair = AsyncStream<Void>.makeStream()

    func wait() async throws {
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }

    func open() {
        pair.continuation.finish()
    }
}

private enum LookaheadFailure: Error, Equatable {
    case translation
    case synthesis
}

private actor LookaheadPlaybackSink: HeptapodSpeechPlaybackSink {
    private let firstGate: LookaheadGate
    private var audio: [Data] = []

    init(firstGate: LookaheadGate) {
        self.firstGate = firstGate
    }

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        audio.append(speech.pcm16)
        if audio.count == 1 {
            try await firstGate.wait()
        }
    }

    func recordedAudio() -> [Data] { audio }
}

private struct LookaheadRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact

    func prepare() async throws {}
    func reset() async {}
    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? { nil }

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        guard chunk.pcm16.isEmpty == false else { return nil }
        return HeptapodTranscriptSegment(text: String(decoding: chunk.pcm16, as: UTF8.self), languageCode: languageHint)
    }
}

private actor LookaheadTranslator: HeptapodTextTranslator {
    nonisolated let descriptor = HeptapodModelDescriptor.madladTranslator
    nonisolated let secondStarted = LookaheadGate()
    nonisolated let secondFinished = LookaheadGate()
    private let secondGate: LookaheadGate?
    private let shouldFail: Bool
    private var texts: [String] = []

    init(secondGate: LookaheadGate? = nil, shouldFail: Bool = false) {
        self.secondGate = secondGate
        self.shouldFail = shouldFail
    }

    func prepare() async throws {}

    func translate(_ text: String, sourceLanguageCode: String?, targetLanguageCode: String) async throws -> HeptapodTranslatedText {
        texts.append(text)
        if texts.count == 2 {
            secondStarted.open()
            defer { secondFinished.open() }
            try await secondGate?.wait()
            if shouldFail { throw LookaheadFailure.translation }
        }
        return HeptapodTranslatedText(
            sourceText: text,
            translatedText: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    func recordedTexts() -> [String] { texts }
}

private actor LookaheadSynthesizer: HeptapodSpeechSynthesizer {
    nonisolated let descriptor = HeptapodModelDescriptor.kokoroTTS
    nonisolated let firstStarted = LookaheadGate()
    nonisolated let firstFinished = LookaheadGate()
    private let firstGate: LookaheadGate?
    private let shouldFail: Bool
    private var texts: [String] = []

    init(firstGate: LookaheadGate? = nil, shouldFail: Bool = false) {
        self.firstGate = firstGate
        self.shouldFail = shouldFail
    }

    func prepare() async throws {}

    func synthesize(_ text: String, languageCode: String, voiceID: String?) async throws -> HeptapodSynthesizedSpeech {
        texts.append(text)
        if texts.count == 1 {
            firstStarted.open()
            defer { firstFinished.open() }
            try await firstGate?.wait()
            if shouldFail { throw LookaheadFailure.synthesis }
        }
        return HeptapodSynthesizedSpeech(pcm16: Data(text.utf8), sampleRate: 24_000, languageCode: languageCode)
    }

    func recordedTexts() -> [String] { texts }
}
