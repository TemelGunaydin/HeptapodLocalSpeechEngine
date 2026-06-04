import Foundation
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
