import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodSpeechSwiftAdapterFactory {
    public static let implementedModelIDs: Set<String> = {
        var modelIDs: Set<String> = [
            HeptapodModelDescriptor.sileroVAD.id,
            HeptapodModelDescriptor.qwenASRCompact.id,
            HeptapodModelDescriptor.qwenASRHighQuality.id,
            HeptapodModelDescriptor.nemotronStreamingASR.id,
            HeptapodModelDescriptor.madladTranslator.id,
            HeptapodModelDescriptor.translateGemma4B.id,
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
        nemotronASRModelID: String = HeptapodNemotronStreamingASRAdapter.defaultModelID,
        translationModelID: String = HeptapodMADLADTranslatorAdapter.defaultModelID,
        translateGemmaModelID: String = HeptapodTranslateGemmaTranslatorAdapter.defaultModelID,
        translateGemmaPythonExecutable: String = ".venv-translategemma/bin/python",
        translateGemmaScriptURL: URL? = nil,
        translationPostEditor: (any HeptapodTranslationPostEditor)? = nil,
        translationPostEditContextLimit: Int = 2,
        ttsModelID: String = HeptapodKokoroTTSAdapter.defaultModelID,
        vadModelID: String = HeptapodSileroVADAdapter.defaultModelID,
        chatterboxPythonExecutable: String = "python3",
        chatterboxScriptURL: URL? = nil,
        chatterboxVoicePromptURL: URL? = nil,
        chatterboxDevice: String? = nil,
        chatterboxExaggeration: Double = 0.5,
        chatterboxCFGWeight: Double = 0.5,
        chatterboxTemperature: Double = 0.8,
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
            recognizer: makeRecognizer(
                for: configuration.speechRecognitionModelID,
                descriptor: recognizerDescriptor,
                qwenModelID: asrModelID,
                nemotronModelID: nemotronASRModelID,
                offlineMode: offlineMode
            ),
            translator: makePostEditingTranslator(
                translator: makeTranslator(
                    for: configuration.textTranslationModelID,
                    madladModelID: translationModelID,
                    translateGemmaModelID: translateGemmaModelID,
                    translateGemmaPythonExecutable: translateGemmaPythonExecutable,
                    translateGemmaScriptURL: translateGemmaScriptURL,
                    offlineMode: offlineMode
                ),
                postEditor: translationPostEditor,
                contextLimit: translationPostEditContextLimit
            ),
            synthesizer: makeSynthesizer(
                for: configuration.speechSynthesisModelID,
                kokoroModelID: ttsModelID,
                chatterboxPythonExecutable: chatterboxPythonExecutable,
                chatterboxScriptURL: chatterboxScriptURL,
                chatterboxVoicePromptURL: chatterboxVoicePromptURL,
                chatterboxDevice: chatterboxDevice,
                chatterboxExaggeration: chatterboxExaggeration,
                chatterboxCFGWeight: chatterboxCFGWeight,
                chatterboxTemperature: chatterboxTemperature,
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

    private static func makeRecognizer(
        for modelID: String,
        descriptor: HeptapodModelDescriptor,
        qwenModelID: String,
        nemotronModelID: String,
        offlineMode: Bool
    ) -> any HeptapodSpeechRecognizer {
        switch modelID {
        case HeptapodModelDescriptor.nemotronStreamingASR.id:
            HeptapodNemotronStreamingASRAdapter(
                descriptor: descriptor,
                modelID: nemotronModelID
            )
        default:
            HeptapodQwen3ASRAdapter(
                descriptor: descriptor,
                modelID: qwenModelID,
                offlineMode: offlineMode
            )
        }
    }

    private static func makePostEditingTranslator(
        translator: any HeptapodTextTranslator,
        postEditor: (any HeptapodTranslationPostEditor)?,
        contextLimit: Int
    ) -> any HeptapodTextTranslator {
        guard let postEditor else {
            return translator
        }
        return HeptapodPostEditingTranslator(
            translator: translator,
            postEditor: postEditor,
            contextLimit: contextLimit
        )
    }

    private static func makeSynthesizer(
        for modelID: String,
        kokoroModelID: String,
        chatterboxPythonExecutable: String,
        chatterboxScriptURL: URL?,
        chatterboxVoicePromptURL: URL?,
        chatterboxDevice: String?,
        chatterboxExaggeration: Double,
        chatterboxCFGWeight: Double,
        chatterboxTemperature: Double,
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
                exaggeration: chatterboxExaggeration,
                cfgWeight: chatterboxCFGWeight,
                temperature: chatterboxTemperature,
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
                exaggeration: chatterboxExaggeration,
                cfgWeight: chatterboxCFGWeight,
                temperature: chatterboxTemperature,
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
        translateGemmaModelID: String,
        translateGemmaPythonExecutable: String,
        translateGemmaScriptURL: URL?,
        offlineMode: Bool
    ) -> any HeptapodTextTranslator {
        switch modelID {
        #if canImport(Translation)
        case HeptapodModelDescriptor.appleTranslation.id:
            HeptapodAppleTranslationAdapter()
        #endif
        case HeptapodModelDescriptor.translateGemma4B.id:
            HeptapodTranslateGemmaTranslatorAdapter(
                pythonExecutable: translateGemmaPythonExecutable,
                scriptURL: translateGemmaScriptURL,
                modelID: translateGemmaModelID
            )
        default:
            HeptapodMADLADTranslatorAdapter(
                modelID: madladModelID,
                offlineMode: offlineMode
            )
        }
    }
}
