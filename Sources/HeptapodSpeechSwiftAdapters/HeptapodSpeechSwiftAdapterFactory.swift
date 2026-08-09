import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodSpeechSwiftAdapterFactory {
    public static let implementedModelIDs: Set<String> = {
        var modelIDs: Set<String> = [
            HeptapodModelDescriptor.sileroVAD.id,
            HeptapodModelDescriptor.qwenASRCompact.id,
            HeptapodModelDescriptor.qwenASRHighQuality.id,
            HeptapodModelDescriptor.madladTranslator.id,
            HeptapodModelDescriptor.mossTTSNano.id,
            HeptapodModelDescriptor.chatterboxMLXTTS.id,
            HeptapodModelDescriptor.chatterboxTTS.id,
            HeptapodModelDescriptor.kokoroTTS.id
        ]
        #if os(macOS)
        modelIDs.insert(HeptapodModelDescriptor.macOSSystemTTS.id)
        #endif
        #if canImport(Translation)
        if #available(macOS 26.0, iOS 26.0, *) {
            modelIDs.insert(HeptapodModelDescriptor.appleTranslation.id)
        }
        #endif
        return modelIDs
    }()

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
        chatterboxUsesPersistentWorker: Bool = true,
        chatterboxMLXPythonExecutable: String = ".venv-chatterbox-mlx/bin/python",
        chatterboxMLXScriptURL: URL? = nil,
        chatterboxMLXVoicePromptURL: URL? = nil,
        chatterboxMLXUsesPersistentWorker: Bool = true,
        mossPythonExecutable: String = ".venv-moss-tts-nano/bin/python",
        mossScriptURL: URL? = nil,
        mossVoicePromptURL: URL? = nil,
        mossDefaultVoice: String = "Ava",
        mossModelDirectoryURL: URL? = nil,
        mossCPUThreads: Int = 8,
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

        let recognizerDescriptor = catalog.model(id: configuration.speechRecognitionModelID)
            ?? HeptapodModelDescriptor.qwenASRCompact

        return try HeptapodSpeechToSpeechPipeline(
            configuration: configuration,
            catalog: catalog,
            vad: vad,
            recognizer: HeptapodQwen3ASRAdapter(
                descriptor: recognizerDescriptor,
                modelID: asrModelID,
                offlineMode: offlineMode
            ),
            translator: makeTranslator(
                for: configuration.textTranslationModelID,
                madladModelID: translationModelID,
                offlineMode: offlineMode
            ),
            synthesizer: makeSynthesizer(
                for: configuration.speechSynthesisModelID,
                kokoroModelID: ttsModelID,
                chatterboxPythonExecutable: chatterboxPythonExecutable,
                chatterboxScriptURL: chatterboxScriptURL,
                chatterboxVoicePromptURL: chatterboxVoicePromptURL,
                chatterboxDevice: chatterboxDevice,
                chatterboxUsesPersistentWorker: chatterboxUsesPersistentWorker,
                chatterboxMLXPythonExecutable: chatterboxMLXPythonExecutable,
                chatterboxMLXScriptURL: chatterboxMLXScriptURL,
                chatterboxMLXVoicePromptURL: chatterboxMLXVoicePromptURL,
                chatterboxMLXUsesPersistentWorker: chatterboxMLXUsesPersistentWorker,
                mossPythonExecutable: mossPythonExecutable,
                mossScriptURL: mossScriptURL,
                mossVoicePromptURL: mossVoicePromptURL,
                mossDefaultVoice: mossDefaultVoice,
                mossModelDirectoryURL: mossModelDirectoryURL,
                mossCPUThreads: mossCPUThreads,
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
        chatterboxUsesPersistentWorker: Bool,
        chatterboxMLXPythonExecutable: String,
        chatterboxMLXScriptURL: URL?,
        chatterboxMLXVoicePromptURL: URL?,
        chatterboxMLXUsesPersistentWorker: Bool,
        mossPythonExecutable: String,
        mossScriptURL: URL?,
        mossVoicePromptURL: URL?,
        mossDefaultVoice: String,
        mossModelDirectoryURL: URL?,
        mossCPUThreads: Int,
        offlineMode: Bool
    ) -> any HeptapodSpeechSynthesizer {
        switch modelID {
        #if os(macOS)
        case HeptapodModelDescriptor.macOSSystemTTS.id:
            HeptapodMacOSSpeechSynthesizerAdapter()
        #endif
        case HeptapodModelDescriptor.chatterboxTTS.id:
            HeptapodChatterboxTTSAdapter(
                pythonExecutable: chatterboxPythonExecutable,
                scriptURL: chatterboxScriptURL,
                voicePromptURL: chatterboxVoicePromptURL,
                device: chatterboxDevice,
                usesPersistentWorker: chatterboxUsesPersistentWorker
            )
        case HeptapodModelDescriptor.chatterboxMLXTTS.id:
            HeptapodChatterboxTTSAdapter(
                descriptor: .chatterboxMLXTTS,
                pythonExecutable: chatterboxMLXPythonExecutable,
                scriptURL: chatterboxMLXScriptURL
                    ?? URL(fileURLWithPath: "Tools/chatterbox_mlx_tts.py"),
                voicePromptURL: chatterboxMLXVoicePromptURL,
                device: "mps",
                usesPersistentWorker: chatterboxMLXUsesPersistentWorker,
                warmsUpPersistentWorker: true
            )
        case HeptapodModelDescriptor.mossTTSNano.id:
            HeptapodMossTTSNanoAdapter(
                pythonExecutable: mossPythonExecutable,
                scriptURL: mossScriptURL,
                voicePromptURL: mossVoicePromptURL,
                defaultVoice: mossDefaultVoice,
                modelDirectoryURL: mossModelDirectoryURL,
                cpuThreads: mossCPUThreads
            )
        default:
            HeptapodKokoroTTSAdapter(modelID: kokoroModelID, offlineMode: offlineMode)
        }
    }

    private static func makeTranslator(
        for modelID: String,
        madladModelID: String,
        offlineMode: Bool
    ) -> any HeptapodTextTranslator {
        switch modelID {
        #if canImport(Translation)
        case HeptapodModelDescriptor.appleTranslation.id:
            HeptapodAppleTranslationAdapter()
        #endif
        default:
            HeptapodMADLADTranslatorAdapter(
                modelID: madladModelID,
                offlineMode: offlineMode
            )
        }
    }
}
