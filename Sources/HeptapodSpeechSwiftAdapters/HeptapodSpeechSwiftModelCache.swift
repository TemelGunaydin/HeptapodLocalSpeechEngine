import AudioCommon
import Foundation
import HeptapodLocalSpeechEngine

public struct HeptapodSpeechSwiftModelCacheStatus: Equatable, Sendable {
    public let descriptor: HeptapodModelDescriptor
    public let modelID: String
    public let cacheDirectory: URL
    public let isCached: Bool
    public let cachedByteCount: Int64

    public var cachedSize: HeptapodByteSize {
        HeptapodByteSize(cachedByteCount)
    }

    public init(
        descriptor: HeptapodModelDescriptor,
        modelID: String,
        cacheDirectory: URL,
        isCached: Bool,
        cachedByteCount: Int64
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
        self.cacheDirectory = cacheDirectory
        self.isCached = isCached
        self.cachedByteCount = cachedByteCount
    }
}

public enum HeptapodSpeechSwiftModelCache {
    public static func starterModelStatuses() throws -> [HeptapodSpeechSwiftModelCacheStatus] {
        try [
            status(descriptor: .sileroVAD, modelID: HeptapodSileroVADAdapter.defaultModelID),
            status(descriptor: .qwenASRCompact, modelID: HeptapodQwen3ASRAdapter.defaultModelID),
            status(descriptor: .madladTranslator, modelID: HeptapodMADLADTranslatorAdapter.defaultModelID),
            status(descriptor: .kokoroTTS, modelID: HeptapodKokoroTTSAdapter.defaultModelID)
        ]
    }

    public static func status(
        descriptor: HeptapodModelDescriptor,
        modelID: String,
        baseCachePath: URL? = nil
    ) throws -> HeptapodSpeechSwiftModelCacheStatus {
        let cacheDirectory = try HuggingFaceDownloader.getCacheDirectory(
            for: modelID,
            basePath: baseCachePath
        )
        let cachedByteCount = byteCount(in: cacheDirectory)
        let isCached = recursiveWeightsExist(in: cacheDirectory)

        return HeptapodSpeechSwiftModelCacheStatus(
            descriptor: descriptor,
            modelID: modelID,
            cacheDirectory: cacheDirectory,
            isCached: isCached,
            cachedByteCount: cachedByteCount
        )
    }

    private static func byteCount(in directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func recursiveWeightsExist(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if HuggingFaceDownloader.weightFileExtensions.contains(fileURL.pathExtension) {
                return true
            }
        }
        return false
    }
}
