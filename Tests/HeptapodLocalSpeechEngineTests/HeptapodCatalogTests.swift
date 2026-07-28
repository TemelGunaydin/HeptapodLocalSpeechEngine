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
    #expect(catalog.models(for: .textTranslation).map(\.id).contains(HeptapodModelDescriptor.appleTranslation.id))
    #expect(catalog.models(for: .speechSynthesis).count >= 2)
    #expect(catalog.models(for: .speechSynthesis).map(\.id).contains(HeptapodModelDescriptor.mossTTSNano.id))
    #expect(catalog.models(for: .speechSynthesis).map(\.id).contains(HeptapodModelDescriptor.chatterboxMLXTTS.id))
    #expect(catalog.models(for: .speechSynthesis).map(\.id).contains(HeptapodModelDescriptor.chatterboxTTS.id))
    #expect(catalog.models(for: .directSpeechToSpeech).isEmpty == false)
    #expect(catalog.models(for: .directSpeechToSpeech).map(\.id).contains(HeptapodModelDescriptor.seamlessStreamingDirectSpeech.id))
}

#if canImport(Translation)
@Test
func speechSwiftFactoryReportsAppleTranslationPipelineRunnable() throws {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.appleTranslation.id,
        speechSynthesisModelID: HeptapodModelDescriptor.mossTTSNano.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.appleTranslation.id))
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline(configuration: configuration)
}

@Test
func appleTranslationAdapterRequiresSourceLanguage() async {
    let adapter = HeptapodAppleTranslationAdapter()

    await #expect(throws: HeptapodAppleTranslationError.sourceLanguageRequired) {
        try await adapter.translate(
            "Hello",
            sourceLanguageCode: nil,
            targetLanguageCode: "tr"
        )
    }
}
#endif

@Test
func seamlessStreamingResearchPipelineIsCataloguedButNotRunnable() throws {
    let catalog = HeptapodModelCatalog()
    let configuration = HeptapodModelCatalog.seamlessStreamingResearchPipeline

    try configuration.validate(in: catalog)

    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)
    #expect(readiness.canRunInference == false)
    #expect(readiness.unavailableDescriptors.map(\.id).contains(HeptapodModelDescriptor.seamlessStreamingDirectSpeech.id))
}

@Test
func nemotronStreamingASRIsCataloguedAsPlannedAdapterCandidate() {
    let catalog = HeptapodModelCatalog()
    let speechRecognitionModels = catalog.models(for: .speechRecognition)

    #expect(speechRecognitionModels.map(\.id).contains(HeptapodModelDescriptor.nemotronStreamingASR.id))
    #expect(HeptapodModelDescriptor.nemotronStreamingASR.status == .planned)
    #expect(HeptapodModelDescriptor.nemotronStreamingASR.capabilities.contains(.streamingASR))

    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.nemotronStreamingASR.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference == false)
    #expect(readiness.unavailableDescriptors.map(\.id).contains(HeptapodModelDescriptor.nemotronStreamingASR.id))
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
func speechSwiftFactoryReportsQualityASRRunnable() {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRHighQuality.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.qwenASRHighQuality.id))
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
func speechSwiftFactoryReportsMossStreamingPipelineRunnable() {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.mossTTSNano.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(HeptapodModelDescriptor.mossTTSNano.capabilities.contains(.streamingTTS))
    #expect(HeptapodModelDescriptor.mossTTSNano.languageCoverage.targetLanguageCodes.contains("tr"))
}

@Test
func speechSwiftFactoryReportsChatterboxMLXPipelineRunnable() {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.chatterboxMLXTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(HeptapodModelDescriptor.chatterboxMLXTTS.languageCoverage.targetLanguageCodes.contains("tr"))
}

#if os(macOS)
@Test
func speechSwiftFactoryReportsMacOSSystemVoicePipelineRunnable() {
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.macOSSystemTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let readiness = HeptapodSpeechSwiftAdapterFactory.readiness(for: configuration)

    #expect(readiness.canRunInference)
    #expect(readiness.unavailableDescriptors.isEmpty)
    #expect(readiness.selectedDescriptors.map(\.id).contains(HeptapodModelDescriptor.macOSSystemTTS.id))
}
#endif

@Test
func speechSwiftFactoryBuildsPipelineWithoutLoadingModels() throws {
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline()
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline(configuration: HeptapodModelCatalog.starterPipeline)
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline(
        configuration: HeptapodPipelineConfiguration(
            speechRecognitionModelID: HeptapodModelDescriptor.qwenASRHighQuality.id,
            textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
            speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
            voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
        ),
        asrModelID: HeptapodQwen3ASRAdapter.highQualityModelID
    )
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
func mossAdapterReportsMissingScriptDuringPrepare() async {
    let adapter = HeptapodMossTTSNanoAdapter(
        scriptURL: URL(fileURLWithPath: "/tmp/heptapod-missing-moss-script-\(UUID().uuidString).py")
    )

    await #expect(throws: HeptapodMossTTSNanoError.self) {
        try await adapter.prepare()
    }
}

@Test
func kokoroAdapterRejectsUnsupportedTurkishBeforeModelLoad() async {
    let adapter = HeptapodKokoroTTSAdapter()

    await #expect(throws: HeptapodKokoroTTSError.self) {
        _ = try await adapter.synthesize("Merhaba", languageCode: "tr-TR", voiceID: nil)
    }
}

#if os(macOS)
@Test
func macOSSystemVoiceAdapterReportsMissingExecutableDuringPrepare() async {
    let adapter = HeptapodMacOSSpeechSynthesizerAdapter(
        executableURL: URL(fileURLWithPath: "/tmp/heptapod-missing-say-\(UUID().uuidString)")
    )

    await #expect(throws: HeptapodMacOSSpeechSynthesizerError.self) {
        try await adapter.prepare()
    }
}
#endif

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
    var playbackStartIndexes: [Int] = []
    var playbackIndexes: [Int] = []
    var translations: [String] = []
    var audioLevels: [HeptapodAudioLevel] = []

    for try await event in events {
        switch event {
        case .segmentStarted(let index):
            startedIndexes.append(index)
        case .audioLevel(_, let level):
            audioLevels.append(level)
        case .silenceSkipped(let index):
            skippedIndexes.append(index)
        case .result(let index, let result):
            resultIndexes.append(index)
            translations.append(result.translation.translatedText)
        case .transcript:
            break
        case .translation:
            break
        case .synthesisAudioReady:
            break
        case .playbackStarted(let index):
            playbackStartIndexes.append(index)
        case .playbackCompleted(let index):
            playbackIndexes.append(index)
        }
    }

    #expect(startedIndexes == [1, 2])
    #expect(skippedIndexes == [1])
    #expect(resultIndexes == [2])
    #expect(playbackStartIndexes == [2])
    #expect(playbackIndexes == [2])
    #expect(translations == ["merhaba"])
    #expect(audioLevels.count == 2)
    #expect(audioLevels.first?.rms == 0)
    #expect((audioLevels.last?.peak ?? 0) > 0)
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
        case .audioLevel:
            break
        case .result(let index, _):
            eventNames.append("result-\(index)")
        case .transcript:
            break
        case .translation:
            break
        case .synthesisAudioReady:
            break
        case .playbackStarted:
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
func liveSessionStreamsFirstAudioBeforeSynthesisCompletes() async throws {
    let probe = StreamingProgressProbe()
    let configuration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.mossTTSNano.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
    let pipeline = try HeptapodSpeechToSpeechPipeline(
        configuration: configuration,
        vad: StubVoiceActivityDetector(),
        recognizer: UTF8ChunkRecognizer(),
        translator: EchoTranslator(),
        synthesizer: ProgressiveSynthesizer(probe: probe)
    )
    let playbackSink = StreamingRecordingPlaybackSink(probe: probe)
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr",
        playbackSink: playbackSink
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [HeptapodAudioChunk(pcm16: Data("hello".utf8), sampleRate: 16_000)]
    )

    let events = await session.run(chunks: source.chunks())
    var resultPCM = Data()
    for try await event in events {
        if case .result(_, let result) = event {
            resultPCM = result.speech.pcm16
        }
    }

    #expect(await probe.wasFirstPlaybackChunkObservedBeforeSynthesisFinished())
    #expect(await playbackSink.streamedChunks() == [Data([1, 2]), Data([3, 4])])
    #expect(resultPCM == Data([1, 2, 3, 4]))
}

@Test
func liveSessionReportsFirstAudioWithoutPlaybackSink() async throws {
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
    let session = HeptapodLiveSpeechSession(
        pipeline: pipeline,
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [HeptapodAudioChunk(pcm16: Data([1, 2, 3]), sampleRate: 16_000)]
    )

    let events = await session.run(chunks: source.chunks())
    var firstAudioIndexes: [Int] = []
    var playbackEventCount = 0
    for try await event in events {
        switch event {
        case .synthesisAudioReady(let index):
            firstAudioIndexes.append(index)
        case .playbackStarted, .playbackCompleted:
            playbackEventCount += 1
        default:
            break
        }
    }

    #expect(firstAudioIndexes == [1])
    #expect(playbackEventCount == 0)
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
    var transcripts: [String] = []
    var translations: [String] = []
    var playbackIndexes: [Int] = []
    var eventNames: [String] = []

    for try await event in events {
        switch event {
        case .transcript(_, let transcript):
            transcripts.append(transcript.text)
            eventNames.append("transcript")
        case .translation(_, let result):
            translations.append(result.translation.translatedText)
            eventNames.append("translation")
        case .playbackCompleted(let index):
            playbackIndexes.append(index)
        case .segmentStarted, .audioLevel, .silenceSkipped, .result, .synthesisAudioReady, .playbackStarted:
            break
        }
    }

    #expect(transcripts == ["first phrase"])
    #expect(translations == ["first phrase"])
    #expect(eventNames == ["transcript", "translation"])
    #expect(playbackIndexes.isEmpty)
    #expect(await playbackSink.playedCount() == 0)
}

@Test
func textOnlyBufferedTranslationNormalizesFragmentedTranscript() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("People.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("People keep asking.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("My first tip.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Is just to.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("listen.".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 5)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var transcripts: [String] = []
    var translations: [String] = []

    for try await event in events {
        switch event {
        case .transcript(_, let transcript):
            transcripts.append(transcript.text)
        case .translation(_, let result):
            translations.append(result.translation.translatedText)
        case .segmentStarted, .audioLevel, .silenceSkipped, .result, .synthesisAudioReady, .playbackStarted, .playbackCompleted:
            break
        }
    }

    #expect(transcripts == [
        "People.",
        "People keep asking.",
        "My first tip.",
        "Is just to.",
        "listen."
    ])
    #expect(translations == [
        "People keep asking. My first tip is just to listen."
    ])
}

@Test
func textOnlyBufferedTranslationPreservesIndependentSentenceStarts() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(
                pcm16: Data("Today we are testing live translation.".utf8),
                sampleRate: 16_000
            ),
            HeptapodAudioChunk(
                pcm16: Data("The translated voice should sound natural.".utf8),
                sampleRate: 16_000
            ),
            HeptapodAudioChunk(
                pcm16: Data("It should preserve sentence boundaries.".utf8),
                sampleRate: 16_000
            ),
            HeptapodAudioChunk(
                pcm16: Data("The book is much.".utf8),
                sampleRate: 16_000
            ),
            HeptapodAudioChunk(
                pcm16: Data("better than I expected.".utf8),
                sampleRate: 16_000
            )
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 5)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []
    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "Today we are testing live translation. The translated voice should sound natural. It should preserve sentence boundaries. The book is much better than I expected."
    ])
}

@Test
func textOnlyBufferedTranslationCarriesIncompleteTailBetweenFlushes() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("Coming soon.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("But my aim here.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Is just to.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("get the advice across.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("To you, as quickly.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("And simply, as.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("possible.".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 3)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []

    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "Coming soon.",
        "But my aim here is just to get the advice across to you, as quickly and simply, as possible."
    ])
}

@Test
func textOnlyBufferedTranslationRetainsCommonContinuationTails() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("People keep.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Asking.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Now I understand that when.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("You are faced.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("So my first.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Tip.".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 1)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []

    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "People keep asking.",
        "Now I understand that when you are faced.",
        "So my first tip."
    ])
}

@Test
func textOnlyBufferedTranslationRetainsLiveASRFragmentTails() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("Something many of us need.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("A peaceful.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Day.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("I feel like.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Like I should lower my voice.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("I should hold.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("A cup of tea.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Where we.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Learn English through.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Through real daily life conversation.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Please hold.".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 1)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []

    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "Something many of us need.",
        "A peaceful day.",
        "I feel like I should lower my voice.",
        "I should hold a cup of tea.",
        "Where we learn English through real daily life conversation.",
        "Please hold."
    ])
}

@Test
func textOnlyBufferedTranslationJoinsDuplicateBoundaryWords() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("Sleep podcast.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Where we learn.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Learn English.".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 3)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []

    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "Sleep podcast. Where we learn English."
    ])
}

@Test
func textOnlyBufferedTranslationJoinsObjectContinuationFragments() async throws {
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
        targetLanguageCode: "tr",
        outputMode: .textOnly
    )
    let source = HeptapodArrayAudioChunkSource(
        audioChunks: [
            HeptapodAudioChunk(pcm16: Data("Today, we are talking.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("About something.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Let me ask you.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("Something.".utf8), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data("When was the last time?".utf8), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(maximumBufferedSegments: 3)

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var translations: [String] = []

    for try await event in events {
        if case .translation(_, let result) = event {
            translations.append(result.translation.translatedText)
        }
    }

    #expect(translations == [
        "Today, we are talking about something.",
        "Let me ask you something. When was the last time?"
    ])
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
        case .transcript:
            break
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
        case .audioLevel:
            break
        case .result(let index, _):
            eventNames.append("result-\(index)")
        case .transcript:
            break
        case .translation:
            break
        case .silenceSkipped, .synthesisAudioReady, .playbackStarted, .playbackCompleted:
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
func sentenceBufferedLiveSessionRetainsTextWhenASRWindowSlides() async throws {
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
            "Today we are testing",
            "Today we are testing local live translation",
            "local live translation the audio should",
            "local live translation the audio should be translated"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 2,
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

    #expect(resultTexts == [
        "Today we are testing local live translation the audio should be translated"
    ])
}

@Test
func sentenceBufferedLiveSessionFallsBackWhenSlidingHypothesesHaveNoCommonPrefix() async throws {
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
            "Today we are testing local",
            "we are testing local live",
            "testing local live translation",
            "local live translation works"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
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

    #expect(resultTexts == ["Today we are testing local live translation works"])
}

@Test
func sentenceBufferedLiveSessionDoesNotRepeatLeadingASRCorrections() async throws {
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
            "sample helps compare latency",
            "sample helps compare latency",
            "Court sample helps compare latency",
            "Court sample helps compare latency"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 2,
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

    #expect(resultTexts == ["sample helps compare latency"])
}

@Test
func sentenceBufferedLiveSessionWaitsPastShortUnstablePrefix() async throws {
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
            "You might",
            "You might",
            "Today we are testing",
            "Today we are testing local translation"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 4,
            minimumStableWords: 3
        )
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var resultTexts: [String] = []

    for try await event in events {
        if case .result(_, let result) = event {
            resultTexts.append(result.transcript.text)
        }
    }

    #expect(resultTexts == ["Today we are testing local translation"])
}

@Test
func sentenceBufferedLiveSessionDoesNotRepeatApproximateASRCorrections() async throws {
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
            "This short example helps compare latency",
            "This short example helps compare latency",
            "A short sample helps compare latency without opening YouTube",
            "A short sample helps compare latency without opening YouTube"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 2,
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

    #expect(resultTexts == [
        "This short example helps compare latency without opening YouTube"
    ])
}

@Test
func sentenceBufferedLiveSessionMergesCorrectedSlidingTailAtStreamEnd() async throws {
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
            "This short sample helps compare latency without opening you to",
            "This short sample helps compare latency without opening you to",
            "short sample helps compare latency without opening YouTube",
            "short sample helps compare latency without opening YouTube"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 5,
            minimumStableWords: 20
        )
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var resultTexts: [String] = []

    for try await event in events {
        if case .result(_, let result) = event {
            resultTexts.append(result.transcript.text)
        }
    }

    #expect(resultTexts == [
        "This short sample helps compare latency without opening YouTube"
    ])
}

@Test
func sentenceBufferedLiveSessionMergesCorrectedTailAfterLeadingWindowNoise() async throws {
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
            "Quickly translated into Turkish and reported with timing in this short example helps compare latency without opening you to",
            "Quickly translated into Turkish and reported with timing in this short example helps compare latency without opening you to",
            "to short sample helps compare latency without opening YouTube",
            "to short sample helps compare latency without opening YouTube"
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
            HeptapodAudioChunk(pcm16: Data([4]), sampleRate: 16_000),
            HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        ]
    )
    let endpointing = HeptapodSentenceEndpointingConfiguration(
        asrStabilization: HeptapodASRStabilizationConfiguration(
            isEnabled: true,
            maximumWindowChunks: 5,
            minimumStableWords: 20
        )
    )

    let events = await session.runSentenceBuffered(chunks: source.chunks(), endpointing: endpointing)
    var resultTexts: [String] = []

    for try await event in events {
        if case .result(_, let result) = event {
            resultTexts.append(result.transcript.text)
        }
    }

    #expect(resultTexts == [
        "Quickly translated into Turkish and reported with timing in this short sample helps compare latency without opening YouTube"
    ])
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

private actor StreamingProgressProbe {
    private let firstChunkEvents: AsyncStream<Void>
    private let firstChunkContinuation: AsyncStream<Void>.Continuation
    private var synthesisFinished = false
    private var firstPlaybackChunkObservedBeforeFinish = false

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        firstChunkEvents = pair.stream
        firstChunkContinuation = pair.continuation
    }

    func markSynthesisFinished() {
        synthesisFinished = true
    }

    func observeFirstPlaybackChunk() {
        firstPlaybackChunkObservedBeforeFinish = synthesisFinished == false
        firstChunkContinuation.yield(())
        firstChunkContinuation.finish()
    }

    func waitForFirstPlaybackChunk() async -> Bool {
        let events = firstChunkEvents
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(2))
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func wasFirstPlaybackChunkObservedBeforeSynthesisFinished() -> Bool {
        firstPlaybackChunkObservedBeforeFinish
    }
}

private actor StreamingRecordingPlaybackSink: HeptapodStreamingSpeechPlaybackSink {
    private let probe: StreamingProgressProbe
    private var chunks: [Data] = []

    init(probe: StreamingProgressProbe) {
        self.probe = probe
    }

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        chunks.append(speech.pcm16)
    }

    func play(
        _ speechStream: AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>
    ) async throws {
        for try await chunk in speechStream {
            if chunks.isEmpty {
                await probe.observeFirstPlaybackChunk()
            }
            chunks.append(chunk.pcm16)
        }
    }

    func streamedChunks() -> [Data] {
        chunks
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

private struct ProgressiveSynthesizer: HeptapodSpeechSynthesizer {
    let descriptor = HeptapodModelDescriptor.mossTTSNano
    let probe: StreamingProgressProbe

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        HeptapodSynthesizedSpeech(
            pcm16: Data([1, 2, 3, 4]),
            sampleRate: 48_000,
            languageCode: languageCode
        )
    }

    func synthesizeStream(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        let probe = probe
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(
                    HeptapodSynthesizedSpeech(
                        pcm16: Data([1, 2]),
                        sampleRate: 48_000,
                        languageCode: languageCode
                    )
                )
                _ = await probe.waitForFirstPlaybackChunk()
                await probe.markSynthesisFinished()
                continuation.yield(
                    HeptapodSynthesizedSpeech(
                        pcm16: Data([3, 4]),
                        sampleRate: 48_000,
                        languageCode: languageCode
                    )
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
