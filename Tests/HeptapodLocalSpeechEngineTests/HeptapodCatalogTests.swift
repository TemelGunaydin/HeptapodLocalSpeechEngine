import Foundation
import HeptapodSpeechSwiftAdapters
import Testing
@testable import HeptapodLocalSpeechEngine

@Test
func starterPipelineIsValidAndHasReadableSize() throws {
    let catalog = HeptapodModelCatalog()
    let configuration = HeptapodModelCatalog.starterPipeline

    try configuration.validate(in: catalog)

    let size = try configuration.estimatedInstalledSize(in: catalog)
    #expect(size.bytes > 0)
    #expect(size.displayText.contains("GB"))
}

@Test
func catalogProvidesAlternativesForEachPipelineStage() {
    let catalog = HeptapodModelCatalog()

    #expect(catalog.models(for: .speechRecognition).count >= 3)
    #expect(catalog.models(for: .textTranslation).count >= 2)
    #expect(catalog.models(for: .speechSynthesis).count >= 2)
    #expect(catalog.models(for: .speechSynthesis).map(\.id).contains(HeptapodModelDescriptor.chatterboxTTS.id))
    #expect(catalog.models(for: .directSpeechToSpeech).isEmpty == false)
}

@Test
func missingModelFailsValidation() {
    let catalog = HeptapodModelCatalog()
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: "missing",
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id
    )

    #expect(throws: HeptapodEngineError.self) {
        try configuration.validate(in: catalog)
    }
}

@Test
func readinessReportsUnimplementedSelectedModels() {
    let readiness = HeptapodUnavailableAdapterFactory.readiness(
        for: HeptapodModelCatalog.starterPipeline
    )

    #expect(readiness.canRunInference == false)
    #expect(readiness.missingStages.isEmpty)
    #expect(readiness.unavailableDescriptors.map(\.id).contains(HeptapodModelDescriptor.qwenASRCompact.id))
    #expect(readiness.unavailableDescriptors.map(\.id).contains(HeptapodModelDescriptor.madladTranslator.id))
    #expect(readiness.unavailableDescriptors.map(\.id).contains(HeptapodModelDescriptor.kokoroTTS.id))
}

@Test
func unavailableFactoryBuildsPipelineThatFailsAtPrepare() async throws {
    let pipeline = try HeptapodUnavailableAdapterFactory.makePipeline(
        configuration: HeptapodModelCatalog.starterPipeline
    )

    await #expect(throws: HeptapodEngineError.self) {
        try await pipeline.prepare()
    }
}

@Test
func speechSwiftFactoryReportsRunnableFilePipeline() {
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(
        for: HeptapodSpeechSwiftAdapterFactory.starterFilePipelineConfiguration
    )

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.qwenASRCompact.id))
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.madladTranslator.id))
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.kokoroTTS.id))
}

@Test
func speechSwiftFactoryReportsStarterPipelineRunnable() {
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(
        for: HeptapodModelCatalog.starterPipeline
    )

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.sileroVAD.id))
}

@Test
func speechSwiftFactoryReportsChatterboxPipelineRunnable() {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.chatterboxTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.chatterboxTTS.id))
}

@Test
func speechSwiftFactoryBuildsPipelineWithoutLoadingModels() throws {
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline()
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline(configuration: HeptapodModelCatalog.starterPipeline)
}

@Test
func chatterboxAdapterReportsMissingScriptDuringPrepare() async {
    let adapter = HeptapodChatterboxTTSAdapter(
        scriptURL: URL(fileURLWithPath: "/tmp/heptapod-missing-chatterbox-script-\(UUID().uuidString).py")
    )

    await #expect(throws: HeptapodChatterboxTTSError.self) {
        try await adapter.prepare()
    }
}

@Test
func speechSwiftCacheStatusesCoverStarterModels() throws {
    let statuses = try HeptapodSpeechSwiftModelCache.starterModelStatuses()

    #expect(statuses.map(\.descriptor.id) == [
        HeptapodModelDescriptor.sileroVAD.id,
        HeptapodModelDescriptor.qwenASRCompact.id,
        HeptapodModelDescriptor.madladTranslator.id,
        HeptapodModelDescriptor.kokoroTTS.id
    ])
    #expect(statuses.allSatisfy { $0.cacheDirectory.path.isEmpty == false })
    #expect(statuses.allSatisfy { $0.cachedByteCount >= 0 })
}

@Test
func detailedPipelineResultPreservesIntermediateOutputs() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        recognizer: StubRecognizer(),
        translator: StubTranslator(),
        synthesizer: StubSynthesizer()
    )

    let result = try await pipeline.processDetailed(
        HeptapodAudioChunk(pcm16: Data([1, 2, 3]), sampleRate: 16_000),
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )

    #expect(result?.transcript.text == "hello")
    #expect(result?.translation.translatedText == "merhaba")
    #expect(result?.speech.languageCode == "tr")
    #expect(result?.speech.pcm16 == Data([9, 9]))
}

@Test
func liveSessionEmitsEventsSkipsSilenceAndPlaysResults() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: StubRecognizer(),
        translator: StubTranslator(),
        synthesizer: StubSynthesizer()
    )
    let playbackSink = RecordingPlaybackSink()
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr",
        playbackSink: playbackSink
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data([1, 2, 3]), sampleRate: 16_000)
        ]
    )

    let events = await session.run(chunks: source.chunks())
    var startedIndexes: [Int] = []
    var skippedIndexes: [Int] = []
    var resultIndexes: [Int] = []
    var playbackIndexes: [Int] = []
    var translations: [String] = []

    for try await event in events {
        switch event {
        case .segmentStarted(let index):
            startedIndexes.append(index)
        case .silenceSkipped(let index):
            skippedIndexes.append(index)
        case .result(let index, let result):
            resultIndexes.append(index)
            translations.append(result.translation.translatedText)
        case .translation:
            break
        case .playbackCompleted(let index):
            playbackIndexes.append(index)
        }
    }

    #expect(startedIndexes == [1, 2])
    #expect(skippedIndexes == [1])
    #expect(resultIndexes == [2])
    #expect(playbackIndexes == [2])
    #expect(translations == ["merhaba"])
    #expect(await playbackSink.playedCount() == 1)
}

@Test
func liveSessionQueuesPlaybackWithoutBlockingNextResult() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: StubSynthesizer()
    )
    let playbackSink = DelayedPlaybackSink(delay: .milliseconds(200))
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr",
        playbackSink: playbackSink
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("first".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("second".utf8), sampleRate: 16_000)
        ]
    )

    let events = await session.run(chunks: source.chunks())
    var eventNames: [String] = []

    for try await event in events {
        switch event {
        case .segmentStarted(let index):
            eventNames.append("segment-\(index)")
        case .result(let index, _):
            eventNames.append("result-\(index)")
        case .translation:
            break
        case .playbackCompleted(let index):
            eventNames.append("playback-\(index)")
        case .silenceSkipped:
            break
        }
    }

    #expect(eventNames.firstIndex(of: "result-2")! < eventNames.firstIndex(of: "playback-1")!)
    #expect(eventNames.suffix(2) == ["playback-1", "playback-2"])
    #expect(await playbackSink.playedCount() == 2)
}

@Test
func liveSessionTextOnlyTranslatesWithoutSynthesisOrPlayback() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: FailingSynthesizer()
    )
    let playbackSink = RecordingPlaybackSink()
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr",
        playbackSink: playbackSink,
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("first phrase".utf8), sampleRate: 16_000)
        ]
    )

    let events = await session.run(chunks: source.chunks())
    var translations: [String] = []
    var playbackIndexes: [Int] = []

    for try await event in events {
        switch event {
        case .translation(_, let result):
            translations.append(result.translation.translatedText)
        case .playbackCompleted(let index):
            playbackIndexes.append(index)
        case .segmentStarted, .silenceSkipped, .result:
            break
        }
    }

    #expect(translations == ["first phrase"])
    #expect(playbackIndexes.isEmpty)
    #expect(await playbackSink.playedCount() == 0)
}

@Test
func sentenceBufferedLiveSessionFlushesOneResultAfterSilence() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: StubSynthesizer()
    )
    let playbackSink = RecordingPlaybackSink()
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr",
        playbackSink: playbackSink
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("One of the goals of".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("the system is speed.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks())
    var resultTexts: [String] = []
    var playbackIndexes: [Int] = []

    for try await event in events {
        switch event {
        case .result(_, let result):
            resultTexts.append(result.transcript.text)
        case .translation:
            break
        case .playbackCompleted(let index):
            playbackIndexes.append(index)
        default:
            break
        }
    }

    #expect(resultTexts == ["One of the goals of the system is speed."])
    #expect(playbackIndexes == [3])
    #expect(await playbackSink.playedCount() == 1)
}

@Test
func sentenceBufferedLiveSessionFlushesAtMaximumBufferedSegments() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: StubSynthesizer()
    )
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("I want to explain".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("how this works".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("before we continue".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 2)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var resultTexts: [String] = []

    for try await event in events {
        if case .result(_, let result) = event {
            resultTexts.append(result.transcript.text)
        }
    }

    #expect(resultTexts == [
        "I want to explain how this works",
        "before we continue"
    ])
}

@Test
func sentenceBufferedLiveSessionQueuesSynthesisWithoutBlockingInput() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: DelayedSynthesizer(delay: .milliseconds(200))
    )
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("first".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("second".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks())
    var eventNames: [String] = []

    for try await event in events {
        switch event {
        case .segmentStarted(let index):
            eventNames.append("segment-\(index)")
        case .result(let index, _):
            eventNames.append("result-\(index)")
        case .translation:
            break
        case .silenceSkipped, .playbackCompleted:
            break
        }
    }

    #expect(eventNames.firstIndex(of: "segment-3")! < eventNames.firstIndex(of: "result-2")!)
    #expect(eventNames.suffix(2) == ["result-2", "result-4"])
}

@Test
func sentenceBufferedLiveSessionUsesStableASRPrefixDeltas() async throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: SequenceRecognizer([
            "I want to",
            "I want to explain",
            "I want to explain how this works"
        ]),
        translator: EchoTranslator(),
        synthesizer: StubSynthesizer()
    )
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data([1]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data([2]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data([3]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 3,
            minimumStableWords: 2
        )
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var resultTexts: [String] = []

    for try await event in events {
        if case .result(_, let result) = event {
            resultTexts.append(result.transcript.text)
        }
    }

    #expect(resultTexts == ["I want to explain how this works"])
}

@Test
func wavFilePlaybackSinkWritesSequentialFiles() async throws {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heptapod-wav-sink-\(UUID().uuidString)")
    let sink = HeptapodWAVFilePlaybackSink(outputDirectory: outputDirectory)

    try await sink.play(HeptapodSynthesizedSpeech(pcm16: Data([0, 0, 1, 0]), sampleRate: 16_000, languageCode: "tr"))
    try await sink.play(HeptapodSynthesizedSpeech(pcm16: Data([0, 0]), sampleRate: 16_000, languageCode: "tr"))

    let files = await sink.writtenFiles()
    #expect(files.map(\.lastPathComponent) == ["segment-001.wav", "segment-002.wav"])
    #expect(FileManager.default.fileExists(atPath: files[0].path))
    #expect(FileManager.default.fileExists(atPath: files[1].path))
}

private struct StubVoiceActivityDetector: HeptapodVoiceActivityDetector {
    let descriptor = HeptapodModelDescriptor.sileroVAD

    func prepare() async throws {}

    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        chunk.pcm16.isEmpty == false
    }
}

private struct StubRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        HeptapodTranscriptSegment(text: "hello", languageCode: languageHint)
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    func reset() async {}
}

private struct UTF8ChunkRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        let text = String(decoding: chunk.pcm16, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return nil
        }
        return HeptapodTranscriptSegment(text: text, languageCode: languageHint)
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    func reset() async {}
}

private actor SequenceRecognizer: HeptapodSpeechRecognizer {
    nonisolated let descriptor = HeptapodModelDescriptor.qwenASRCompact
    private var texts: [String]

    init(_ texts: [String]) {
        self.texts = texts
    }

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        guard texts.isEmpty == false else {
            return nil
        }
        return HeptapodTranscriptSegment(text: texts.removeFirst(), languageCode: languageHint)
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    func reset() async {
        texts.removeAll()
    }
}

private actor RecordingPlaybackSink: HeptapodSpeechPlaybackSink {
    private var playedSpeech: [HeptapodSynthesizedSpeech] = []

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        playedSpeech.append(speech)
    }

    func playedCount() -> Int {
        playedSpeech.count
    }
}

private actor DelayedPlaybackSink: HeptapodSpeechPlaybackSink {
    private let delay: Duration
    private var playedSpeech: [HeptapodSynthesizedSpeech] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        try await Task.sleep(for: delay)
        playedSpeech.append(speech)
    }

    func playedCount() -> Int {
        playedSpeech.count
    }
}

private struct StubTranslator: HeptapodTextTranslator {
    let descriptor = HeptapodModelDescriptor.madladTranslator

    func prepare() async throws {}

    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        HeptapodTranslatedText(
            sourceText: text,
            translatedText: "merhaba",
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }
}

private struct EchoTranslator: HeptapodTextTranslator {
    let descriptor = HeptapodModelDescriptor.madladTranslator

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
            targetLanguageCode: targetLanguageCode
        )
    }
}

private struct StubSynthesizer: HeptapodSpeechSynthesizer {
    let descriptor = HeptapodModelDescriptor.kokoroTTS

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        HeptapodSynthesizedSpeech(pcm16: Data([9, 9]), sampleRate: 16_000, languageCode: languageCode)
    }
}

private struct DelayedSynthesizer: HeptapodSpeechSynthesizer {
    let descriptor = HeptapodModelDescriptor.kokoroTTS
    let delay: Duration

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        try await Task.sleep(for: delay)
        return HeptapodSynthesizedSpeech(pcm16: Data([9, 9]), sampleRate: 16_000, languageCode: languageCode)
    }
}

private struct FailingSynthesizer: HeptapodSpeechSynthesizer {
    let descriptor = HeptapodModelDescriptor.kokoroTTS

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        throw HeptapodEngineError.adapterNotImplemented("text-only test should not synthesize")
    }
}
