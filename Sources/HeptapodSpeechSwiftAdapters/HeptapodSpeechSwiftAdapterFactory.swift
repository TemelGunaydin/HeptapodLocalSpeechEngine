import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodSpeechSwiftAdapterFactory {
    public static let implementedModelIDs: Set<String> = [
        HeptapodModelDescriptor.sileroVAD.id,
        HeptapodModelDescriptor.qwenASRCompact.id,
        HeptapodModelDescriptor.madladTranslator.id,
        HeptapodModelDescriptor.chatterboxTTS.id,
        HeptapodModelDescriptor.kokoroTTS.id
    ]

    public static let starterFilePipelineConfiguration = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id
    )

    public static func makePipeline(
        configuration: HeptapodPipelineConfiguration = starterFilePipelineConfiguration,
        catalog: HeptapodModelCatalog = HeptapodModelCatalog(),
        asrModelID: String = HeptapodQwen3ASRAdapter.defaultModelID,
        translationModelID: String = HeptapodMADLADTranslatorAdapter.defaultModelID,
        ttsModelID: String = HeptapodKokoroTTSAdapter.defaultModelID,
        vadModelID: String = HeptapodSileroVADAdapter.defaultModelID,
        chatterboxPythonExecutable: String = "python3",
        chatterboxScriptURL: URL? = nil,
        chatterboxVoicePromptURL: URL? = nil,
        chatterboxDevice: String? = nil,
        offlineMode: Bool = false
    ) throws -> HeptapodSpeechToSpeechPipeline {
        try requireImplemented(configuration.speechRecognitionModelID, stage: .speechRecognition)
        try requireImplemented(configuration.textTranslationModelID, stage: .textTranslation)
        try requireImplemented(configuration.speechSynthesisModelID, stage: .speechSynthesis)

        let vad: (any HeptapodVoiceActivityDetector)?
        if let voiceActivityModelID = configuration.voiceActivityModelID {
            try requireImplemented(voiceActivityModelID, stage: .voiceActivityDetection)
            vad = HeptapodSileroVADAdapter(modelID: vadModelID, offlineMode: offlineMode)
        } else {
            vad = nil
        }

        return try HeptapodSpeechToSpeechPipeline(
            configuration: configuration,
            catalog: catalog,
            vad: vad,
            recognizer: HeptapodQwen3ASRAdapter(modelID: asrModelID, offlineMode: offlineMode),
            translator: HeptapodMADLADTranslatorAdapter(modelID: translationModelID, offlineMode: offlineMode),
            synthesizer: makeSynthesizer(
                for: configuration.speechSynthesisModelID,
                kokoroModelID: ttsModelID,
                chatterboxPythonExecutable: chatterboxPythonExecutable,
                chatterboxScriptURL: chatterboxScriptURL,
                chatterboxVoicePromptURL: chatterboxVoicePromptURL,
                chatterboxDevice: chatterboxDevice,
                offlineMode: offlineMode
            )
        )
    }

    public static func readiness(
        for configuration: HeptapodPipelineConfiguration,
        in catalog: HeptapodModelCatalog = HeptapodModelCatalog()
    ) -> HeptapodPipelineReadiness {
        configuration.readiness(in: catalog, implementedModelIDs: implementedModelIDs)
    }

    private static func requireImplemented(
        _ id: String,
        stage: HeptapodPipelineStage
    ) throws {
        guard implementedModelIDs.contains(id) else {
            throw HeptapodEngineError.adapterNotImplemented(id)
        }
    }

    private static func makeSynthesizer(
        for modelID: String,
        kokoroModelID: String,
        chatterboxPythonExecutable: String,
        chatterboxScriptURL: URL?,
        chatterboxVoicePromptURL: URL?,
        chatterboxDevice: String?,
        offlineMode: Bool
    ) -> any HeptapodSpeechSynthesizer {
        switch modelID {
        case HeptapodModelDescriptor.chatterboxTTS.id:
            HeptapodChatterboxTTSAdapter(
                pythonExecutable: chatterboxPythonExecutable,
                scriptURL: chatterboxScriptURL,
                voicePromptURL: chatterboxVoicePromptURL,
                device: chatterboxDevice
            )
        default:
            HeptapodKokoroTTSAdapter(modelID: kokoroModelID, offlineMode: offlineMode)
        }
    }
}
