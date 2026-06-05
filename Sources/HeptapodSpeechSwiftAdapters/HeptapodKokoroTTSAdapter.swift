import Foundation
import HeptapodLocalSpeechEngine
import KokoroTTS

public actor HeptapodKokoroTTSAdapter: HeptapodSpeechSynthesizer {
    public static let defaultModelID = KokoroTTSModel.defaultModelId
    public static let outputSampleRate = KokoroTTSModel.outputSampleRate
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
        let model = try await preparedModel()
        let samples = try model.synthesize(
            text: text,
            voice: voiceID ?? defaultVoiceID,
            language: languageCode
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
