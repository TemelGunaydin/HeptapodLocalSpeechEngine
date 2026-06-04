import Foundation

public struct HeptapodPipelineConfiguration: Codable, Equatable, Sendable {
    public let speechRecognitionModelID: String
    public let textTranslationModelID: String
    public let speechSynthesisModelID: String
    public let voiceActivityModelID: String?
    public let directSpeechToSpeechModelID: String?

    public init(
        speechRecognitionModelID: String,
        textTranslationModelID: String,
        speechSynthesisModelID: String,
        voiceActivityModelID: String? = nil,
        directSpeechToSpeechModelID: String? = nil
    ) {
        self.speechRecognitionModelID = speechRecognitionModelID
        self.textTranslationModelID = textTranslationModelID
        self.speechSynthesisModelID = speechSynthesisModelID
        self.voiceActivityModelID = voiceActivityModelID
        self.directSpeechToSpeechModelID = directSpeechToSpeechModelID
    }

    public func descriptors(in catalog: HeptapodModelCatalog) throws -> [HeptapodModelDescriptor] {
        let requiredIDs = [
            speechRecognitionModelID,
            textTranslationModelID,
            speechSynthesisModelID
        ]
        let optionalIDs = [voiceActivityModelID, directSpeechToSpeechModelID].compactMap { $0 }
        let ids = requiredIDs + optionalIDs

        return try ids.map { id in
            guard let descriptor = catalog.model(id: id) else {
                throw HeptapodEngineError.unsupportedModel(id)
            }
            return descriptor
        }
    }

    public func estimatedInstalledSize(in catalog: HeptapodModelCatalog) throws -> HeptapodByteSize {
        let totalBytes = try descriptors(in: catalog)
            .map(\.footprint.installedSize.bytes)
            .reduce(0, +)
        return HeptapodByteSize(totalBytes)
    }

    public func readiness(
        in catalog: HeptapodModelCatalog,
        implementedModelIDs: Set<String>
    ) -> HeptapodPipelineReadiness {
        let requiredStageIDs: [(HeptapodPipelineStage, String)] = [
            (.speechRecognition, speechRecognitionModelID),
            (.textTranslation, textTranslationModelID),
            (.speechSynthesis, speechSynthesisModelID)
        ]
        let optionalStageIDs: [(HeptapodPipelineStage, String)] = [
            voiceActivityModelID.map { (.voiceActivityDetection, $0) },
            directSpeechToSpeechModelID.map { (.directSpeechToSpeech, $0) }
        ].compactMap { $0 }

        let stageIDs = requiredStageIDs + optionalStageIDs
        let selectedDescriptors = stageIDs.compactMap { stage, id in
            catalog.model(id: id).flatMap { descriptor in
                descriptor.stage == stage ? descriptor : nil
            }
        }
        let missingStages = stageIDs.compactMap { stage, id in
            guard catalog.model(id: id)?.stage == stage else { return stage }
            return nil
        }
        let unavailableDescriptors = selectedDescriptors.filter { descriptor in
            !implementedModelIDs.contains(descriptor.id)
        }

        return HeptapodPipelineReadiness(
            selectedDescriptors: selectedDescriptors,
            missingStages: missingStages,
            unavailableDescriptors: unavailableDescriptors
        )
    }

    public func validate(in catalog: HeptapodModelCatalog) throws {
        let descriptors = try descriptors(in: catalog)

        try require(.speechRecognition, id: speechRecognitionModelID, descriptors: descriptors)
        try require(.textTranslation, id: textTranslationModelID, descriptors: descriptors)
        try require(.speechSynthesis, id: speechSynthesisModelID, descriptors: descriptors)

        if let voiceActivityModelID {
            try require(.voiceActivityDetection, id: voiceActivityModelID, descriptors: descriptors)
        }

        if let directSpeechToSpeechModelID {
            try require(.directSpeechToSpeech, id: directSpeechToSpeechModelID, descriptors: descriptors)
        }
    }

    private func require(
        _ stage: HeptapodPipelineStage,
        id: String,
        descriptors: [HeptapodModelDescriptor]
    ) throws {
        guard descriptors.contains(where: { $0.id == id && $0.stage == stage }) else {
            throw HeptapodEngineError.missingComponent(stage)
        }
    }
}
