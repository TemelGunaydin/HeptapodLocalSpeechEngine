import Foundation

public struct HeptapodModelCatalog: Sendable {
    public let models: [HeptapodModelDescriptor]

    public init(models: [HeptapodModelDescriptor] = HeptapodModelCatalog.defaultModels) {
        self.models = models
    }

    public func model(id: String) -> HeptapodModelDescriptor? {
        models.first { $0.id == id }
    }

    public func models(for stage: HeptapodPipelineStage) -> [HeptapodModelDescriptor] {
        models
            .filter { $0.stage == stage }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status.sortRank < rhs.status.sortRank
                }
                return lhs.footprint.installedSize < rhs.footprint.installedSize
            }
    }

    public static let defaultModels: [HeptapodModelDescriptor] = [
        .sileroVAD,
        .qwenASRCompact,
        .qwenASRHighQuality,
        .whisperKitBase,
        .whisperKitLarge,
        .parakeetStreaming,
        .madladTranslator,
        .nllbDistilledTranslator,
        .seamlessTextTranslator,
        .qwenTTSCompact,
        .kokoroTTS,
        .cosyVoiceTTS,
        .seamlessDirectSpeech
    ]

    public static let starterPipeline = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )

    public static let qualityPipeline = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.qwenASRHighQuality.id,
        textTranslationModelID: HeptapodModelDescriptor.nllbDistilledTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.qwenTTSCompact.id,
        voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
    )
}

private extension HeptapodModelStatus {
    var sortRank: Int {
        switch self {
        case .ready: 0
        case .adapterRequired: 1
        case .planned: 2
        case .research: 3
        }
    }
}

public extension HeptapodModelDescriptor {
    static let sileroVAD = HeptapodModelDescriptor(
        id: "vad.silero.coreml",
        stage: .voiceActivityDetection,
        displayName: "Silero VAD",
        provider: "Silero",
        family: "Silero VAD",
        backend: .coreML,
        capabilities: [.vad],
        qualityTier: .balanced,
        latencyTier: .realtime,
        status: .adapterRequired,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(6),
            installedSize: .megabytes(8),
            recommendedMemory: .megabytes(64)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Language-agnostic speech activity detection."),
        summary: "Small VAD gate to avoid running ASR/translation/TTS on silence.",
        tradeoffs: "Very low cost, but it only decides speech/no-speech."
    )

    static let qwenASRCompact = HeptapodModelDescriptor(
        id: "asr.qwen3.0_6b.mlx.4bit",
        stage: .speechRecognition,
        displayName: "Qwen3 ASR 0.6B 4-bit",
        provider: "Qwen / Soniqo",
        family: "Qwen3-ASR",
        backend: .mlxSwift,
        capabilities: [.batchASR],
        qualityTier: .starter,
        latencyTier: .segmentBased,
        status: .ready,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(680),
            installedSize: .megabytes(760),
            recommendedMemory: .gigabytes(4)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Multilingual ASR, best as local starter/default model."),
        summary: "Compact ASR for Basic/Starter local mode.",
        tradeoffs: "Good disk footprint and speed; less robust than larger ASR models on noisy audio."
    )

    static let qwenASRHighQuality = HeptapodModelDescriptor(
        id: "asr.qwen3.1_7b.mlx.8bit",
        stage: .speechRecognition,
        displayName: "Qwen3 ASR 1.7B 8-bit",
        provider: "Qwen / Soniqo",
        family: "Qwen3-ASR",
        backend: .mlxSwift,
        capabilities: [.batchASR],
        qualityTier: .highQuality,
        latencyTier: .segmentBased,
        status: .ready,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(3.2),
            installedSize: .gigabytes(3.6),
            recommendedMemory: .gigabytes(8)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Better for accents, lectures, noisy audio, and long-form speech."),
        summary: "Higher-accuracy ASR for users who accept larger downloads.",
        tradeoffs: "Higher memory and first-load cost; not ideal for low-end devices."
    )

    static let whisperKitBase = HeptapodModelDescriptor(
        id: "asr.whisperkit.base.coreml",
        stage: .speechRecognition,
        displayName: "WhisperKit Base",
        provider: "Argmax / OpenAI Whisper",
        family: "WhisperKit",
        backend: .whisperKit,
        capabilities: [.batchASR, .streamingASR, .wordTimestamps, .speechToTextTranslation],
        qualityTier: .balanced,
        latencyTier: .nearRealtime,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(150),
            installedSize: .megabytes(220),
            recommendedMemory: .gigabytes(4)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Strong multilingual ASR; Whisper translation is mainly to English."),
        summary: "Good fallback for streaming ASR and word timestamps.",
        tradeoffs: "Translation support is not full target-language S2ST; CoreML model management differs from MLX."
    )

    static let whisperKitLarge = HeptapodModelDescriptor(
        id: "asr.whisperkit.large_v3.coreml",
        stage: .speechRecognition,
        displayName: "WhisperKit Large v3",
        provider: "Argmax / OpenAI Whisper",
        family: "WhisperKit",
        backend: .whisperKit,
        capabilities: [.batchASR, .streamingASR, .wordTimestamps, .speechToTextTranslation],
        qualityTier: .maximum,
        latencyTier: .nearRealtime,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(2.9),
            installedSize: .gigabytes(3.4),
            recommendedMemory: .gigabytes(12)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Very strong ASR; heavier local footprint."),
        summary: "Maximum ASR quality option for high-end Macs.",
        tradeoffs: "Large install size and memory use; may not be acceptable as a default model."
    )

    static let parakeetStreaming = HeptapodModelDescriptor(
        id: "asr.parakeet.streaming.coreml.int8",
        stage: .speechRecognition,
        displayName: "Parakeet Streaming ASR",
        provider: "NVIDIA / Soniqo",
        family: "Parakeet",
        backend: .coreML,
        capabilities: [.streamingASR],
        qualityTier: .balanced,
        latencyTier: .realtime,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(260),
            installedSize: .megabytes(340),
            recommendedMemory: .gigabytes(4)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Best fit when true partial ASR is more important than broad language coverage."),
        summary: "Streaming-first ASR alternative.",
        tradeoffs: "Language coverage may be narrower than Qwen/Whisper depending on model variant."
    )

    static let madladTranslator = HeptapodModelDescriptor(
        id: "mt.madlad400.3b.mlx",
        stage: .textTranslation,
        displayName: "MADLAD-400 3B",
        provider: "Google / Soniqo",
        family: "MADLAD",
        backend: .mlxSwift,
        capabilities: [.textTranslation],
        qualityTier: .balanced,
        latencyTier: .segmentBased,
        status: .ready,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(2.4),
            installedSize: .gigabytes(2.8),
            recommendedMemory: .gigabytes(8)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Broad multilingual text translation."),
        summary: "Practical first local translation model.",
        tradeoffs: "Quality may lag cloud translation for idioms, domain terms, and low-resource language pairs."
    )

    static let nllbDistilledTranslator = HeptapodModelDescriptor(
        id: "mt.nllb.distilled.600m",
        stage: .textTranslation,
        displayName: "NLLB Distilled 600M",
        provider: "Meta",
        family: "NLLB",
        backend: .custom,
        capabilities: [.textTranslation],
        qualityTier: .highQuality,
        latencyTier: .segmentBased,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(1.3),
            installedSize: .gigabytes(1.6),
            recommendedMemory: .gigabytes(6)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Strong multilingual translation candidate if converted to an Apple-friendly runtime."),
        summary: "Potential quality upgrade for text translation.",
        tradeoffs: "Requires conversion/runtime work; not a native Swift adapter yet."
    )

    static let seamlessTextTranslator = HeptapodModelDescriptor(
        id: "mt.seamless_m4t_v2.text",
        stage: .textTranslation,
        displayName: "SeamlessM4T v2 Text",
        provider: "Meta",
        family: "SeamlessM4T",
        backend: .seamless,
        capabilities: [.textTranslation, .speechToTextTranslation],
        qualityTier: .research,
        latencyTier: .offline,
        status: .research,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(4.0),
            installedSize: .gigabytes(4.8),
            recommendedMemory: .gigabytes(12)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Research-grade multilingual translation stack."),
        summary: "Research path for a more unified speech translation system.",
        tradeoffs: "Heavy, harder to package, and not a clean Swift-native production dependency."
    )

    static let kokoroTTS = HeptapodModelDescriptor(
        id: "tts.kokoro.82m.coreml",
        stage: .speechSynthesis,
        displayName: "Kokoro 82M",
        provider: "Kokoro / Soniqo",
        family: "Kokoro",
        backend: .coreML,
        capabilities: [.batchTTS],
        qualityTier: .starter,
        latencyTier: .nearRealtime,
        status: .adapterRequired,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(90),
            installedSize: .megabytes(130),
            recommendedMemory: .gigabytes(2)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Small TTS option; language and voice coverage depend on packaged voices."),
        summary: "Smallest practical local TTS option.",
        tradeoffs: "Not as natural or expressive as larger TTS models."
    )

    static let qwenTTSCompact = HeptapodModelDescriptor(
        id: "tts.qwen3.0_6b.mlx.4bit",
        stage: .speechSynthesis,
        displayName: "Qwen3 TTS 0.6B 4-bit",
        provider: "Qwen / Soniqo",
        family: "Qwen3-TTS",
        backend: .mlxSwift,
        capabilities: [.batchTTS, .streamingTTS, .voiceCloning],
        qualityTier: .highQuality,
        latencyTier: .nearRealtime,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(980),
            installedSize: .gigabytes(1.2),
            recommendedMemory: .gigabytes(6)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Good quality TTS with limited but useful language coverage."),
        summary: "Best candidate for natural local speech output.",
        tradeoffs: "Bigger than Kokoro and may compete with ASR/translation for GPU memory."
    )

    static let cosyVoiceTTS = HeptapodModelDescriptor(
        id: "tts.cosyvoice3.0_5b.mlx.4bit",
        stage: .speechSynthesis,
        displayName: "CosyVoice3 0.5B 4-bit",
        provider: "Alibaba / Soniqo",
        family: "CosyVoice",
        backend: .mlxSwift,
        capabilities: [.batchTTS, .voiceCloning],
        qualityTier: .highQuality,
        latencyTier: .nearRealtime,
        status: .planned,
        footprint: HeptapodModelFootprint(
            downloadSize: .megabytes(760),
            installedSize: .gigabytes(1.0),
            recommendedMemory: .gigabytes(6)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Good expressive TTS candidate for supported languages."),
        summary: "Alternative expressive TTS model.",
        tradeoffs: "Adapter and voice management are separate integration work."
    )

    static let seamlessDirectSpeech = HeptapodModelDescriptor(
        id: "s2st.seamless_m4t_v2.large",
        stage: .directSpeechToSpeech,
        displayName: "SeamlessM4T v2 Speech-to-Speech",
        provider: "Meta",
        family: "SeamlessM4T",
        backend: .seamless,
        capabilities: [.directSpeechToSpeech, .speechToTextTranslation],
        qualityTier: .research,
        latencyTier: .offline,
        status: .research,
        footprint: HeptapodModelFootprint(
            downloadSize: .gigabytes(8.0),
            installedSize: .gigabytes(10.0),
            recommendedMemory: .gigabytes(16)
        ),
        languageCoverage: HeptapodLanguageCoverage(notes: "Direct S2ST research path across many languages."),
        summary: "Closest single-model family to OpenAI-style speech-to-speech.",
        tradeoffs: "Heavy and not yet suitable as a first native macOS production path."
    )
}
