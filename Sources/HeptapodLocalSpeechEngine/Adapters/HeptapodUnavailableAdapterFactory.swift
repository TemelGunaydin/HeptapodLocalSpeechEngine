import Foundation

public enum HeptapodUnavailableAdapterFactory {
    public static let implementedModelIDs: Set<String> = []

    public static func makePipeline(
        configuration: HeptapodPipelineConfiguration,
        catalog: HeptapodModelCatalog = HeptapodModelCatalog()
    ) throws -> HeptapodSpeechToSpeechPipeline {
        try configuration.validate(in: catalog)

        let vad = try configuration.voiceActivityModelID.map { id in
            HeptapodUnavailableVoiceActivityDetector(descriptor: try descriptor(id: id, stage: .voiceActivityDetection, catalog: catalog))
        }

        return try HeptapodSpeechToSpeechPipeline(
            configuration: configuration,
            catalog: catalog,
            vad: vad,
            recognizer: HeptapodUnavailableSpeechRecognizer(
                descriptor: try descriptor(id: configuration.speechRecognitionModelID, stage: .speechRecognition, catalog: catalog)
            ),
            translator: HeptapodUnavailableTextTranslator(
                descriptor: try descriptor(id: configuration.textTranslationModelID, stage: .textTranslation, catalog: catalog)
            ),
            synthesizer: HeptapodUnavailableSpeechSynthesizer(
                descriptor: try descriptor(id: configuration.speechSynthesisModelID, stage: .speechSynthesis, catalog: catalog)
            )
        )
    }

    public static func readiness(
        for configuration: HeptapodPipelineConfiguration,
        in catalog: HeptapodModelCatalog = HeptapodModelCatalog()
    ) -> HeptapodPipelineReadiness {
        configuration.readiness(in: catalog, implementedModelIDs: implementedModelIDs)
    }

    private static func descriptor(
        id: String,
        stage: HeptapodPipelineStage,
        catalog: HeptapodModelCatalog
    ) throws -> HeptapodModelDescriptor {
        guard let descriptor = catalog.model(id: id), descriptor.stage == stage else {
            throw HeptapodEngineError.missingComponent(stage)
        }
        return descriptor
    }
}
