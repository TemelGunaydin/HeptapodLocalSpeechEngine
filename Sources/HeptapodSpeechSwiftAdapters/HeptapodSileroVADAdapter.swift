import Foundation
import HeptapodLocalSpeechEngine
import SpeechVAD

public actor HeptapodSileroVADAdapter: HeptapodVoiceActivityDetector {
    public static let defaultModelID = SileroVADModel.defaultCoreMLModelId
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let modelID: String
    private let cacheDir: URL?
    private let offlineMode: Bool
    private let engine: SileroVADEngine
    private var model: SileroVADModel?

    public init(
        descriptor: HeptapodModelDescriptor = .sileroVAD,
        modelID: String = HeptapodSileroVADAdapter.defaultModelID,
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        engine: SileroVADEngine = .coreml
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
        self.cacheDir = cacheDir
        self.offlineMode = offlineMode
        self.engine = engine
    }

    public func prepare() async throws {
        _ = try await preparedModel()
    }

    public func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        let model = try await preparedModel()
        let audio = HeptapodSpeechSwiftAudioSamples.floatSamples(
            from: chunk,
            targetSampleRate: SileroVADModel.sampleRate
        )
        let segments = model.detectSpeech(audio: audio, sampleRate: SileroVADModel.sampleRate)
        return segments.isEmpty == false
    }

    private func preparedModel() async throws -> SileroVADModel {
        if let model {
            return model
        }

        let loaded = try await SileroVADModel.fromPretrained(
            modelId: modelID,
            engine: engine,
            cacheDir: cacheDir,
            offlineMode: offlineMode
        )
        model = loaded
        return loaded
    }
}
