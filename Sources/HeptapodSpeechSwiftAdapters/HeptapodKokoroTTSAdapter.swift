import Foundation
import HeptapodLocalSpeechEngine
import KokoroTTS

public actor HeptapodKokoroTTSAdapter: HeptapodSpeechSynthesizer {
    public static let defaultModelID = KokoroTTSModel.defaultModelId
    public static let outputSampleRate = KokoroTTSModel.outputSampleRate
    public static let supportedLanguageCodes: Set<String> = [
        "en", "fr", "es", "ja", "zh", "hi", "pt", "it"
    ]
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let modelID: String
    private let cacheDir: URL?
    private let offlineMode: Bool
    private let defaultVoiceID: String
    private var model: KokoroTTSModel?

    public init(
        descriptor: HeptapodModelDescriptor = .kokoroTTS,
        modelID: String = HeptapodKokoroTTSAdapter.defaultModelID,
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        defaultVoiceID: String = KokoroTTSModel.defaultVoice
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
        self.cacheDir = cacheDir
        self.offlineMode = offlineMode
        self.defaultVoiceID = defaultVoiceID
    }

    public func prepare() async throws {
        _ = try await preparedModel()
    }

    public func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        let normalizedLanguageCode = languageCode
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? languageCode
        guard Self.supportedLanguageCodes.contains(normalizedLanguageCode) else {
            throw HeptapodKokoroTTSError.unsupportedLanguage(languageCode)
        }

        let model = try await preparedModel()
        let samples = try model.synthesize(
            text: text,
            voice: voiceID ?? defaultVoiceID,
            language: normalizedLanguageCode
        )
        return HeptapodSynthesizedSpeech(
            pcm16: HeptapodSpeechSwiftAudioSamples.pcm16Data(from: samples),
            sampleRate: Self.outputSampleRate,
            languageCode: languageCode
        )
    }

    private func preparedModel() async throws -> KokoroTTSModel {
        if let model {
            return model
        }

        let loaded = try await KokoroTTSModel.fromPretrained(
            modelId: modelID,
            cacheDir: cacheDir,
            offlineMode: offlineMode
        )
        model = loaded
        return loaded
    }
}

public enum HeptapodKokoroTTSError: LocalizedError, Sendable {
    case unsupportedLanguage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let languageCode):
            "Kokoro does not support language '\(languageCode)'. Use the macOS system voice or Chatterbox Multilingual for Turkish speech."
        }
    }
}
