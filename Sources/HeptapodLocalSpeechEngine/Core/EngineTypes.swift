import Foundation

public enum HeptapodPipelineStage: String, CaseIterable, Codable, Sendable {
    case voiceActivityDetection
    case speechRecognition
    case textTranslation
    case speechSynthesis
    case directSpeechToSpeech
}

public enum HeptapodBackend: String, Codable, Sendable {
    case mlxSwift
    case coreML
    case whisperKit
    case whisperCpp
    case onnxRuntime
    case seamless
    case custom
}

public enum HeptapodCapability: String, Codable, Sendable {
    case vad
    case batchASR
    case streamingASR
    case speechToTextTranslation
    case textTranslation
    case batchTTS
    case streamingTTS
    case directSpeechToSpeech
    case voiceCloning
    case wordTimestamps
}

public enum HeptapodQualityTier: String, Codable, Sendable {
    case starter
    case balanced
    case highQuality
    case maximum
    case research
}

public enum HeptapodLatencyTier: String, Codable, Sendable {
    case realtime
    case nearRealtime
    case segmentBased
    case offline
}

public enum HeptapodModelStatus: String, Codable, Sendable {
    case ready
    case adapterRequired
    case planned
    case research
}

public struct HeptapodByteSize: Codable, Equatable, Comparable, Sendable {
    public let bytes: Int64

    public init(_ bytes: Int64) {
        self.bytes = max(0, bytes)
    }

    public static func megabytes(_ value: Double) -> HeptapodByteSize {
        HeptapodByteSize(Int64((value * 1_048_576).rounded()))
    }

    public static func gigabytes(_ value: Double) -> HeptapodByteSize {
        HeptapodByteSize(Int64((value * 1_073_741_824).rounded()))
    }

    public var displayText: String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1_024 {
            return String(format: "~%.1f GB", megabytes / 1_024)
        }
        return "~\(Int(megabytes.rounded())) MB"
    }

    public static func < (lhs: HeptapodByteSize, rhs: HeptapodByteSize) -> Bool {
        lhs.bytes < rhs.bytes
    }
}

public struct HeptapodModelFootprint: Codable, Equatable, Sendable {
    public let downloadSize: HeptapodByteSize
    public let installedSize: HeptapodByteSize
    public let recommendedMemory: HeptapodByteSize?

    public init(
        downloadSize: HeptapodByteSize,
        installedSize: HeptapodByteSize,
        recommendedMemory: HeptapodByteSize? = nil
    ) {
        self.downloadSize = downloadSize
        self.installedSize = installedSize
        self.recommendedMemory = recommendedMemory
    }
}

public struct HeptapodLanguageCoverage: Codable, Equatable, Sendable {
    public let sourceLanguageCodes: Set<String>
    public let targetLanguageCodes: Set<String>
    public let notes: String

    public init(
        sourceLanguageCodes: Set<String> = [],
        targetLanguageCodes: Set<String> = [],
        notes: String = ""
    ) {
        self.sourceLanguageCodes = sourceLanguageCodes
        self.targetLanguageCodes = targetLanguageCodes
        self.notes = notes
    }
}

public struct HeptapodModelDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let stage: HeptapodPipelineStage
    public let displayName: String
    public let provider: String
    public let family: String
    public let backend: HeptapodBackend
    public let capabilities: Set<HeptapodCapability>
    public let qualityTier: HeptapodQualityTier
    public let latencyTier: HeptapodLatencyTier
    public let status: HeptapodModelStatus
    public let footprint: HeptapodModelFootprint
    public let languageCoverage: HeptapodLanguageCoverage
    public let summary: String
    public let tradeoffs: String
    public let licenseNote: String

    public init(
        id: String,
        stage: HeptapodPipelineStage,
        displayName: String,
        provider: String,
        family: String,
        backend: HeptapodBackend,
        capabilities: Set<HeptapodCapability>,
        qualityTier: HeptapodQualityTier,
        latencyTier: HeptapodLatencyTier,
        status: HeptapodModelStatus,
        footprint: HeptapodModelFootprint,
        languageCoverage: HeptapodLanguageCoverage,
        summary: String,
        tradeoffs: String,
        licenseNote: String = "Verify model license before distribution."
    ) {
        self.id = id
        self.stage = stage
        self.displayName = displayName
        self.provider = provider
        self.family = family
        self.backend = backend
        self.capabilities = capabilities
        self.qualityTier = qualityTier
        self.latencyTier = latencyTier
        self.status = status
        self.footprint = footprint
        self.languageCoverage = languageCoverage
        self.summary = summary
        self.tradeoffs = tradeoffs
        self.licenseNote = licenseNote
    }
}

public struct HeptapodAudioChunk: Sendable {
    public let pcm16: Data
    public let sampleRate: Int
    public let channelCount: Int

    public init(pcm16: Data, sampleRate: Int, channelCount: Int = 1) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct HeptapodTranscriptSegment: Equatable, Sendable {
    public let text: String
    public let languageCode: String?
    public let isFinal: Bool
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?

    public init(
        text: String,
        languageCode: String? = nil,
        isFinal: Bool = true,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.text = text
        self.languageCode = languageCode
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct HeptapodTranslatedText: Equatable, Sendable {
    public let sourceText: String
    public let translatedText: String
    public let sourceLanguageCode: String?
    public let targetLanguageCode: String

    public init(
        sourceText: String,
        translatedText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}

public struct HeptapodSynthesizedSpeech: Sendable {
    public let pcm16: Data
    public let sampleRate: Int
    public let languageCode: String

    public init(pcm16: Data, sampleRate: Int, languageCode: String) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.languageCode = languageCode
    }
}

public struct HeptapodSpeechToSpeechResult: Sendable {
    public let transcript: HeptapodTranscriptSegment
    public let translation: HeptapodTranslatedText
    public let speech: HeptapodSynthesizedSpeech

    public init(
        transcript: HeptapodTranscriptSegment,
        translation: HeptapodTranslatedText,
        speech: HeptapodSynthesizedSpeech
    ) {
        self.transcript = transcript
        self.translation = translation
        self.speech = speech
    }
}

public struct HeptapodPipelineReadiness: Equatable, Sendable {
    public let selectedDescriptors: [HeptapodModelDescriptor]
    public let missingStages: [HeptapodPipelineStage]
    public let unavailableDescriptors: [HeptapodModelDescriptor]

    public init(
        selectedDescriptors: [HeptapodModelDescriptor],
        missingStages: [HeptapodPipelineStage],
        unavailableDescriptors: [HeptapodModelDescriptor]
    ) {
        self.selectedDescriptors = selectedDescriptors
        self.missingStages = missingStages
        self.unavailableDescriptors = unavailableDescriptors
    }

    public var canRunInference: Bool {
        missingStages.isEmpty && unavailableDescriptors.isEmpty
    }
}
