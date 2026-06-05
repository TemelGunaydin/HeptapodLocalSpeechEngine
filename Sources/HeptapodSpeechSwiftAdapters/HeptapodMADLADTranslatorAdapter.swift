import Foundation
import HeptapodLocalSpeechEngine
import MADLADTranslation

public actor HeptapodMADLADTranslatorAdapter: HeptapodTextTranslator {
    public static let defaultModelID = MADLADTranslator.defaultModelId
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let modelID: String
    private let cacheDir: URL?
    private let offlineMode: Bool
    private var translator: MADLADTranslator?

    public init(
        descriptor: HeptapodModelDescriptor = .madladTranslator,
        modelID: String = HeptapodMADLADTranslatorAdapter.defaultModelID,
        cacheDir: URL? = nil,
        offlineMode: Bool = false
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
        self.cacheDir = cacheDir
        self.offlineMode = offlineMode
    }

    public func prepare() async throws {
        _ = try await preparedTranslator()
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let translator = try await preparedTranslator()
        let translatedText = try translator.translate(text, to: targetLanguageCode)

        return HeptapodTranslatedText(
            sourceText: text,
            translatedText: translatedText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    private func preparedTranslator() async throws -> MADLADTranslator {
        if let translator {
            return translator
        }

        let loaded = try await MADLADTranslator.fromPretrained(
            modelId: modelID,
            cacheDir: cacheDir,
            offlineMode: offlineMode
        )
        translator = loaded
        return loaded
    }
}
