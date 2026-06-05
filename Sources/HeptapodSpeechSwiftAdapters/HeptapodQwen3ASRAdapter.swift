import Foundation
import HeptapodLocalSpeechEngine
import Qwen3ASR

public actor HeptapodQwen3ASRAdapter: HeptapodSpeechRecognizer {
    public static let defaultModelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let modelID: String
    private let cacheDir: URL?
    private let offlineMode: Bool
    private var model: Qwen3ASRModel?

    public init(
        descriptor: HeptapodModelDescriptor = .qwenASRCompact,
        modelID: String = HeptapodQwen3ASRAdapter.defaultModelID,
        cacheDir: URL? = nil,
        offlineMode: Bool = false
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
        self.cacheDir = cacheDir
        self.offlineMode = offlineMode
    }

    public func prepare() async throws {
        _ = try await preparedModel()
    }

    public func transcribe(
        _ chunk: HeptapodAudioChunk,
        languageHint: String?
    ) async throws -> HeptapodTranscriptSegment? {
        let model = try await preparedModel()
        let audio = HeptapodSpeechSwiftAudioSamples.floatSamples(from: chunk, targetSampleRate: 16_000)
        let text = model.transcribe(audio: audio, sampleRate: 16_000, language: languageHint)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.isEmpty == false else {
            return nil
        }

        return HeptapodTranscriptSegment(
            text: text,
            languageCode: languageHint,
            isFinal: true
        )
    }

    public func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    public func reset() async {}

    private func preparedModel() async throws -> Qwen3ASRModel {
        if let model {
            return model
        }

        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: modelID,
            cacheDir: cacheDir,
            offlineMode: offlineMode
        )
        model = loaded
        return loaded
    }
}
